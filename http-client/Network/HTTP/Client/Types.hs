{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.HTTP.Client.Types
    ( BodyReader
    , Connection (..)
    , StatusHeaders (..)
    , HttpException (..)
    , HttpExceptionContent (..)
    , unHttpExceptionContentWrapper
    , throwHttp
    , toHttpException
    , Cookie (..)
    , equalCookie
    , equivCookie
    , compareCookies
    , CookieJar (..)
    , equalCookieJar
    , equivCookieJar
    , Proxy (..)
    , RequestBody (..)
    , Popper
    , NeedsPopper
    , GivesPopper
    , Request (..)
    , Response (..)
    , ResponseClose (..)
    , Manager (..)
    , HasHttpManager (..)
    , ConnsMap (..)
    , ManagerSettings (..)
    , NonEmptyList (..)
    , ConnHost (..)
    , ConnKey (..)
    , ProxyOverride (..)
    , StreamFileStatus (..)
    , ResponseTimeout (..)
    , ProxySecureMode (..)
    , RequestTrace (..)
    , GotConnectionInfo (..)
    , DNSStartInfo (..)
    , DNSDoneInfo (..)
    ) where

import qualified Data.Typeable as T (Typeable)
import Network.HTTP.Types
import Control.Exception (Exception, SomeException, throwIO)
import Data.Word (Word64)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import Blaze.ByteString.Builder (Builder, fromLazyByteString, fromByteString, toLazyByteString)
import Data.Int (Int64)
import Data.Foldable (Foldable)
import Data.Monoid (Monoid(..))
import Data.Semigroup (Semigroup(..))
import Data.String (IsString, fromString)
import Data.Time (UTCTime)
import Data.Traversable (Traversable)
import qualified Data.List as DL
import Network.Socket (HostAddress)
import Data.IORef
import qualified Network.Socket as NS
import qualified Data.Map as Map
import Data.Text (Text)
import Data.Streaming.Zlib (ZlibException)
import Data.CaseInsensitive as CI
import Data.KeyedPool (KeyedPool)
import Data.ByteString (ByteString)

-- | An @IO@ action that represents an incoming response body coming from the
-- server. Data provided by this action has already been gunzipped and
-- de-chunked, and respects any content-length headers present.
--
-- The action gets a single chunk of data from the response body, or an empty
-- bytestring if no more data is available.
--
-- Since 0.4.0
type BodyReader = IO S.ByteString

data Connection = Connection
    { connectionRead :: IO S.ByteString
      -- ^ If no more data, return empty.
    , connectionUnread :: S.ByteString -> IO ()
      -- ^ Return data to be read next time.
    , connectionWrite :: S.ByteString -> IO ()
      -- ^ Send data to server
    , connectionClose :: IO ()
      -- ^ Close connection. Any successive operation on the connection
      -- (except closing) should fail with `ConnectionClosed` exception.
      -- It is allowed to close connection multiple times.
    }
    deriving T.Typeable

data StatusHeaders = StatusHeaders Status HttpVersion RequestHeaders
    deriving (Show, Eq, Ord, T.Typeable)

-- | A newtype wrapper which is not exported from this library but is an
-- instance of @Exception@. This allows @HttpExceptionContent@ to be thrown
-- (via this wrapper), but users of the library can't accidentally try to catch
-- it (when they /should/ be trying to catch 'HttpException').
--
-- @since 0.5.0
newtype HttpExceptionContentWrapper = HttpExceptionContentWrapper
    { unHttpExceptionContentWrapper :: HttpExceptionContent
    }
    deriving (Show, T.Typeable)
instance Exception HttpExceptionContentWrapper

throwHttp :: HttpExceptionContent -> IO a
throwHttp = throwIO . HttpExceptionContentWrapper

toHttpException :: Request -> HttpExceptionContentWrapper -> HttpException
toHttpException req (HttpExceptionContentWrapper e) = HttpExceptionRequest req e

-- | An exception which may be generated by this library
--
-- @since 0.5.0
data HttpException
    = HttpExceptionRequest Request HttpExceptionContent
    -- ^ Most exceptions are specific to a 'Request'. Inspect the
    -- 'HttpExceptionContent' value for details on what occurred.
    --
    -- @since 0.5.0
    | InvalidUrlException String String
    -- ^ A URL (first field) is invalid for a given reason
    -- (second argument).
    --
    -- @since 0.5.0
    deriving (Show, T.Typeable)
instance Exception HttpException

data HttpExceptionContent
                   = StatusCodeException (Response ()) S.ByteString
                   -- ^ Generated by the @parseUrlThrow@ function when the
                   -- server returns a non-2XX response status code.
                   --
                   -- May include the beginning of the response body.
                   --
                   -- @since 0.5.0
                   | TooManyRedirects [Response L.ByteString]
                   -- ^ The server responded with too many redirects for a
                   -- request.
                   --
                   -- Contains the list of encountered responses containing
                   -- redirects in reverse chronological order; including last
                   -- redirect, which triggered the exception and was not
                   -- followed.
                   --
                   -- @since 0.5.0
                   | OverlongHeaders
                   -- ^ Either too many headers, or too many total bytes in a
                   -- single header, were returned by the server, and the
                   -- memory exhaustion protection in this library has kicked
                   -- in.
                   --
                   -- @since 0.5.0
                   | ResponseTimeout
                   -- ^ The server took too long to return a response. This can
                   -- be altered via 'responseTimeout' or
                   -- 'managerResponseTimeout'.
                   --
                   -- @since 0.5.0
                   | ConnectionTimeout
                   -- ^ Attempting to connect to the server timed out.
                   --
                   -- @since 0.5.0
                   | ConnectionFailure SomeException
                   -- ^ An exception occurred when trying to connect to the
                   -- server.
                   --
                   -- @since 0.5.0
                   | InvalidStatusLine S.ByteString
                   -- ^ The status line returned by the server could not be parsed.
                   --
                   -- @since 0.5.0
                   | InvalidHeader S.ByteString
                   -- ^ The given response header line could not be parsed
                   --
                   -- @since 0.5.0
                   | InvalidRequestHeader S.ByteString
                   -- ^ The given request header is not compliant (e.g. has newlines)
                   --
                   -- @since 0.5.14
                   | InternalException SomeException
                   -- ^ An exception was raised by an underlying library when
                   -- performing the request. Most often, this is caused by a
                   -- failing socket action or a TLS exception.
                   --
                   -- @since 0.5.0
                   | ProxyConnectException S.ByteString Int Status
                   -- ^ A non-200 status code was returned when trying to
                   -- connect to the proxy server on the given host and port.
                   --
                   -- @since 0.5.0
                   | NoResponseDataReceived
                   -- ^ No response data was received from the server at all.
                   -- This exception may deserve special handling within the
                   -- library, since it may indicate that a pipelining has been
                   -- used, and a connection thought to be open was in fact
                   -- closed.
                   --
                   -- @since 0.5.0
                   | TlsNotSupported
                   -- ^ Exception thrown when using a @Manager@ which does not
                   -- have support for secure connections. Typically, you will
                   -- want to use @tlsManagerSettings@ from @http-client-tls@
                   -- to overcome this.
                   --
                   -- @since 0.5.0
                   | WrongRequestBodyStreamSize Word64 Word64
                   -- ^ The request body provided did not match the expected size.
                   --
                   -- Provides the expected and actual size.
                   --
                   -- @since 0.4.31
                   | ResponseBodyTooShort Word64 Word64
                   -- ^ The returned response body is too short. Provides the
                   -- expected size and actual size.
                   --
                   -- @since 0.5.0
                   | InvalidChunkHeaders
                   -- ^ A chunked response body had invalid headers.
                   --
                   -- @since 0.5.0
                   | IncompleteHeaders
                   -- ^ An incomplete set of response headers were returned.
                   --
                   -- @since 0.5.0
                   | InvalidDestinationHost S.ByteString
                   -- ^ The host we tried to connect to is invalid (e.g., an
                   -- empty string).
                   | HttpZlibException ZlibException
                   -- ^ An exception was thrown when inflating a response body.
                   --
                   -- @since 0.5.0
                   | InvalidProxyEnvironmentVariable Text Text
                   -- ^ Values in the proxy environment variable were invalid.
                   -- Provides the environment variable name and its value.
                   --
                   -- @since 0.5.0
                   | ConnectionClosed
                   -- ^ Attempted to use a 'Connection' which was already closed
                   --
                   -- @since 0.5.0
                   | InvalidProxySettings Text
                   -- ^ Proxy settings are not valid (Windows specific currently)
                   -- @since 0.5.7
    deriving (Show, T.Typeable)

-- Purposely not providing this instance, since we don't want users to
-- accidentally try and catch these exceptions instead of HttpException
--
-- instance Exception HttpExceptionContent


-- This corresponds to the description of a cookie detailed in Section 5.3 \"Storage Model\"
data Cookie = Cookie
  { cookie_name :: S.ByteString
  , cookie_value :: S.ByteString
  , cookie_expiry_time :: UTCTime
  , cookie_domain :: S.ByteString
  , cookie_path :: S.ByteString
  , cookie_creation_time :: UTCTime
  , cookie_last_access_time :: UTCTime
  , cookie_persistent :: Bool
  , cookie_host_only :: Bool
  , cookie_secure_only :: Bool
  , cookie_http_only :: Bool
  }
  deriving (Read, Show, T.Typeable)

newtype CookieJar = CJ { expose :: [Cookie] }
  deriving (Read, Show, T.Typeable)

-- | Instead of '(==)'.
--
-- Since there was some confusion in the history of this library about how the 'Eq' instance
-- should work, it was removed for clarity, and replaced by 'equal' and 'equiv'.  'equal'
-- gives you equality of all fields of the 'Cookie' record.
--
-- @since 0.7.0
equalCookie :: Cookie -> Cookie -> Bool
equalCookie a b = and
  [ cookie_name a == cookie_name b
  , cookie_value a == cookie_value b
  , cookie_expiry_time a == cookie_expiry_time b
  , cookie_domain a == cookie_domain b
  , cookie_path a == cookie_path b
  , cookie_creation_time a == cookie_creation_time b
  , cookie_last_access_time a == cookie_last_access_time b
  , cookie_persistent a == cookie_persistent b
  , cookie_host_only a == cookie_host_only b
  , cookie_secure_only a == cookie_secure_only b
  , cookie_http_only a == cookie_http_only b
  ]

-- | Equality of name, domain, path only.  This corresponds to step 11 of the algorithm
-- described in Section 5.3 \"Storage Model\".  See also: 'equal'.
--
-- @since 0.7.0
equivCookie :: Cookie -> Cookie -> Bool
equivCookie a b = name_matches && domain_matches && path_matches
  where name_matches = cookie_name a == cookie_name b
        domain_matches = CI.foldCase (cookie_domain a) == CI.foldCase (cookie_domain b)
        path_matches = cookie_path a == cookie_path b

-- | Instead of @instance Ord Cookie@.  See 'equalCookie', 'equivCookie'.
--
-- @since 0.7.0
compareCookies :: Cookie -> Cookie -> Ordering
compareCookies c1 c2
    | S.length (cookie_path c1) > S.length (cookie_path c2) = LT
    | S.length (cookie_path c1) < S.length (cookie_path c2) = GT
    | cookie_creation_time c1 > cookie_creation_time c2 = GT
    | otherwise = LT

-- | See 'equalCookie'.
--
-- @since 0.7.0
equalCookieJar :: CookieJar -> CookieJar -> Bool
equalCookieJar (CJ cj1) (CJ cj2) = and $ zipWith equalCookie cj1 cj2

-- | See 'equalCookieJar', 'equalCookie'.
--
-- @since 0.7.0
equivCookieJar :: CookieJar -> CookieJar -> Bool
equivCookieJar cj1 cj2 = and $
  zipWith equivCookie (DL.sortBy compareCookies $ expose cj1) (DL.sortBy compareCookies $ expose cj2)

instance Semigroup CookieJar where
  (CJ a) <> (CJ b) = CJ (DL.nubBy equivCookie $ DL.sortBy mostRecentFirst $ a <> b)
    where mostRecentFirst c1 c2 =
            -- inverse so that recent cookies are kept by nub over older
            if cookie_creation_time c1 > cookie_creation_time c2
                then LT
                else GT

-- | Since 1.9
instance Data.Monoid.Monoid CookieJar where
  mempty = CJ []
#if !(MIN_VERSION_base(4,11,0))
  mappend = (<>)
#endif

-- | Define a HTTP proxy, consisting of a hostname and port number.

data Proxy = Proxy
    { proxyHost :: S.ByteString -- ^ The host name of the HTTP proxy.
    , proxyPort :: Int -- ^ The port number of the HTTP proxy.
    }
    deriving (Show, Read, Eq, Ord, T.Typeable)

-- | Define how to make secure connections using a proxy server.
data ProxySecureMode =
  ProxySecureWithConnect
  -- ^ Use the HTTP CONNECT verb to forward a secure connection through the proxy.
  | ProxySecureWithoutConnect
  -- ^ Send the request directly to the proxy with an https URL. This mode can be
  -- used to offload TLS handling to a trusted local proxy.
  deriving (Show, Read, Eq, Ord, T.Typeable)

-- | When using one of the 'RequestBodyStream' \/ 'RequestBodyStreamChunked'
-- constructors, you must ensure that the 'GivesPopper' can be called multiple
-- times.  Usually this is not a problem.
--
-- The 'RequestBodyStreamChunked' will send a chunked request body. Note that
-- not all servers support this. Only use 'RequestBodyStreamChunked' if you
-- know the server you're sending to supports chunked request bodies.
--
-- Since 0.1.0
data RequestBody
    = RequestBodyLBS L.ByteString
    | RequestBodyBS S.ByteString
    | RequestBodyBuilder Int64 Builder
    | RequestBodyStream Int64 (GivesPopper ())
    | RequestBodyStreamChunked (GivesPopper ())
    | RequestBodyIO (IO RequestBody)
    -- ^ Allows creation of a @RequestBody@ inside the @IO@ monad, which is
    -- useful for making easier APIs (like @setRequestBodyFile@).
    --
    -- @since 0.4.28
    deriving T.Typeable
-- |
--
-- Since 0.4.12
instance IsString RequestBody where
    fromString str = RequestBodyBS (fromString str)
instance Monoid RequestBody where
    mempty = RequestBodyBS S.empty
#if !(MIN_VERSION_base(4,11,0))
    mappend = (<>)
#endif

instance Semigroup RequestBody where
    x0 <> y0 =
        case (simplify x0, simplify y0) of
            (Left (i, x), Left (j, y)) -> RequestBodyBuilder (i + j) (x <> y)
            (Left x, Right y) -> combine (builderToStream x) y
            (Right x, Left y) -> combine x (builderToStream y)
            (Right x, Right y) -> combine x y
      where
        combine (Just i, x) (Just j, y) = RequestBodyStream (i + j) (combine' x y)
        combine (_, x) (_, y) = RequestBodyStreamChunked (combine' x y)

        combine' :: GivesPopper () -> GivesPopper () -> GivesPopper ()
        combine' x y f = x $ \x' -> y $ \y' -> combine'' x' y' f

        combine'' :: Popper -> Popper -> NeedsPopper () -> IO ()
        combine'' x y f = do
            istate <- newIORef $ Left (x, y)
            f $ go istate

        go istate = do
            state <- readIORef istate
            case state of
                Left (x, y) -> do
                    bs <- x
                    if S.null bs
                        then do
                            writeIORef istate $ Right y
                            y
                        else return bs
                Right y -> y

simplify :: RequestBody -> Either (Int64, Builder) (Maybe Int64, GivesPopper ())
simplify (RequestBodyLBS lbs) = Left (L.length lbs, fromLazyByteString lbs)
simplify (RequestBodyBS bs) = Left (fromIntegral $ S.length bs, fromByteString bs)
simplify (RequestBodyBuilder len b) = Left (len, b)
simplify (RequestBodyStream i gp) = Right (Just i, gp)
simplify (RequestBodyStreamChunked gp) = Right (Nothing, gp)
simplify (RequestBodyIO _mbody) = error "FIXME No support for Monoid on RequestBodyIO"

builderToStream :: (Int64, Builder) -> (Maybe Int64, GivesPopper ())
builderToStream (len, builder) =
    (Just len, gp)
  where
    gp np = do
        ibss <- newIORef $ L.toChunks $ toLazyByteString builder
        np $ do
            bss <- readIORef ibss
            case bss of
                [] -> return S.empty
                bs:bss' -> do
                    writeIORef ibss bss'
                    return bs

-- | A function which generates successive chunks of a request body, provider a
-- single empty bytestring when no more data is available.
--
-- Since 0.1.0
type Popper = IO S.ByteString

-- | A function which must be provided with a 'Popper'.
--
-- Since 0.1.0
type NeedsPopper a = Popper -> IO a

-- | A function which will provide a 'Popper' to a 'NeedsPopper'. This
-- seemingly convoluted structure allows for creation of request bodies which
-- allocate scarce resources in an exception safe manner.
--
-- Since 0.1.0
type GivesPopper a = NeedsPopper a -> IO a

-- | All information on how to connect to a host and what should be sent in the
-- HTTP request.
--
-- If you simply wish to download from a URL, see 'parseRequest'.
--
-- The constructor for this data type is not exposed. Instead, you should use
-- either the 'defaultRequest' value, or 'parseRequest' to
-- construct from a URL, and then use the records below to make modifications.
-- This approach allows http-client to add configuration options without
-- breaking backwards compatibility.
--
-- For example, to construct a POST request, you could do something like:
--
-- > initReq <- parseRequest "http://www.example.com/path"
-- > let req = initReq
-- >             { method = "POST"
-- >             }
--
-- For more information, please see
-- <http://www.yesodweb.com/book/settings-types>.
--
-- Since 0.1.0
data Request = Request
    { method :: Method
    -- ^ HTTP request method, eg GET, POST.
    --
    -- Since 0.1.0
    , secure :: Bool
    -- ^ Whether to use HTTPS (ie, SSL).
    --
    -- Since 0.1.0
    , host :: S.ByteString
    -- ^ Requested host name, used for both the IP address to connect to and
    -- the @host@ request header.
    --
    -- Since 0.1.0
    , port :: Int
    -- ^ The port to connect to. Also used for generating the @host@ request header.
    --
    -- Since 0.1.0
    , path :: S.ByteString
    -- ^ Everything from the host to the query string.
    --
    -- Since 0.1.0
    , queryString :: S.ByteString
    -- ^ Query string appended to the path.
    --
    -- Since 0.1.0
    , requestHeaders :: RequestHeaders
    -- ^ Custom HTTP request headers
    --
    -- The Content-Length and Transfer-Encoding headers are set automatically
    -- by this module, and shall not be added to @requestHeaders@.
    --
    -- If not provided by the user, @Host@ will automatically be set based on
    -- the @host@ and @port@ fields.
    --
    -- Moreover, the Accept-Encoding header is set implicitly to gzip for
    -- convenience by default. This behaviour can be overridden if needed, by
    -- setting the header explicitly to a different value. In order to omit the
    -- Accept-Header altogether, set it to the empty string \"\". If you need an
    -- empty Accept-Header (i.e. requesting the identity encoding), set it to a
    -- non-empty white-space string, e.g. \" \". See RFC 2616 section 14.3 for
    -- details about the semantics of the Accept-Header field. If you request a
    -- content-encoding not supported by this module, you will have to decode
    -- it yourself (see also the 'decompress' field).
    --
    -- Note: Multiple header fields with the same field-name will result in
    -- multiple header fields being sent and therefore it\'s the responsibility
    -- of the client code to ensure that the rules from RFC 2616 section 4.2
    -- are honoured.
    --
    -- Since 0.1.0
    , requestBody :: RequestBody
    -- ^ Request body to be sent to the server.
    --
    -- Since 0.1.0
    , proxy :: Maybe Proxy
    -- ^ Optional HTTP proxy.
    --
    -- Since 0.1.0
    , hostAddress :: Maybe HostAddress
    -- ^ Optional resolved host address. May not be used by all backends.
    --
    -- Since 0.1.0
    , rawBody :: Bool
    -- ^ If @True@, a chunked and\/or gzipped body will not be
    -- decoded. Use with caution.
    --
    -- Since 0.1.0
    , decompress :: S.ByteString -> Bool
    -- ^ Predicate to specify whether gzipped data should be
    -- decompressed on the fly (see 'alwaysDecompress' and
    -- 'browserDecompress'). Argument is the mime type.
    -- Default: browserDecompress.
    --
    -- Since 0.1.0
    , redirectCount :: Int
    -- ^ How many redirects to follow when getting a resource. 0 means follow
    -- no redirects. Default value: 10.
    --
    -- Since 0.1.0
    , checkResponse :: Request -> Response BodyReader -> IO ()
    -- ^ Check the response immediately after receiving the status and headers.
    -- This can be useful for throwing exceptions on non-success status codes.
    --
    -- In previous versions of http-client, this went under the name
    -- @checkStatus@, but was renamed to avoid confusion about the new default
    -- behavior (doing nothing).
    --
    -- @since 0.5.0
    , responseTimeout :: ResponseTimeout
    -- ^ Number of microseconds to wait for a response (see 'ResponseTimeout'
    -- for more information). Default: use 'managerResponseTimeout' (which by
    -- default is 30 seconds).
    --
    -- Since 0.1.0
    , cookieJar :: Maybe CookieJar
    -- ^ A user-defined cookie jar.
    -- If 'Nothing', no cookie handling will take place, \"Cookie\" headers
    -- in 'requestHeaders' will be sent raw, and 'responseCookieJar' will be
    -- empty.
    --
    -- Since 0.1.0

    , requestVersion :: HttpVersion
    -- ^ HTTP version to send to server.
    --
    -- Default: HTTP 1.1
    --
    -- Since 0.4.3

    , onRequestBodyException :: SomeException -> IO ()
    -- ^ How to deal with exceptions thrown while sending the request.
    --
    -- Default: ignore @IOException@s, rethrow all other exceptions.
    --
    -- Since: 0.4.6

    , requestManagerOverride :: Maybe Manager
    -- ^ A 'Manager' value that should override whatever @Manager@ value was
    -- passed in to the HTTP request function manually. This is useful when
    -- dealing with implicit global managers, such as in @Network.HTTP.Simple@
    --
    -- @since 0.4.28

    , shouldStripHeaderOnRedirect :: HeaderName -> Bool
    -- ^ Decide whether a header must be stripped from the request
    -- when following a redirect. Default: keep all headers intact.
    --
    -- @since 0.6.2

    , proxySecureMode :: ProxySecureMode
    -- ^ How to proxy an HTTPS request.
    --
    -- Default: Use HTTP CONNECT.
    --
    -- @since 0.7.2
    , hooks :: RequestTrace
    -- ^ Hooks for performing actions on different portions of the
    -- request lifecycle. Default: does nothing.
    --
    -- @since 0.7.10
    }
    deriving T.Typeable

-- | How to deal with timing out on retrieval of response headers.
--
-- @since 0.5.0
data ResponseTimeout
    = ResponseTimeoutMicro !Int
    -- ^ Wait the given number of microseconds for response headers to
    -- load, then throw an exception
    | ResponseTimeoutNone
    -- ^ Wait indefinitely
    | ResponseTimeoutDefault
    -- ^ Fall back to the manager setting ('managerResponseTimeout') or, in its
    -- absence, Wait 30 seconds and then throw an exception.
    deriving (Eq, Show)

instance Show Request where
    show x = unlines
        [ "Request {"
        , "  host                 = " ++ show (host x)
        , "  port                 = " ++ show (port x)
        , "  secure               = " ++ show (secure x)
        , "  requestHeaders       = " ++ show (DL.map redactSensitiveHeader (requestHeaders x))
        , "  path                 = " ++ show (path x)
        , "  queryString          = " ++ show (queryString x)
        --, "  requestBody          = " ++ show (requestBody x)
        , "  method               = " ++ show (method x)
        , "  proxy                = " ++ show (proxy x)
        , "  rawBody              = " ++ show (rawBody x)
        , "  redirectCount        = " ++ show (redirectCount x)
        , "  responseTimeout      = " ++ show (responseTimeout x)
        , "  requestVersion       = " ++ show (requestVersion x)
        , "  proxySecureMode      = " ++ show (proxySecureMode x)
        , "}"
        ]

redactSensitiveHeader :: Header -> Header
redactSensitiveHeader ("Authorization", _) = ("Authorization", "<REDACTED>")
redactSensitiveHeader h = h

-- | A simple representation of the HTTP response.
--
-- Since 0.1.0
data Response body = Response
    { responseStatus :: Status
    -- ^ Status code of the response.
    --
    -- Since 0.1.0
    , responseVersion :: HttpVersion
    -- ^ HTTP version used by the server.
    --
    -- Since 0.1.0
    , responseHeaders :: ResponseHeaders
    -- ^ Response headers sent by the server.
    --
    -- Since 0.1.0
    , responseBody :: body
    -- ^ Response body sent by the server.
    --
    -- Since 0.1.0
    , responseCookieJar :: CookieJar
    -- ^ Cookies set on the client after interacting with the server. If
    -- cookies have been disabled by setting 'cookieJar' to @Nothing@, then
    -- this will always be empty.
    --
    -- Since 0.1.0
    , responseClose' :: ResponseClose
    -- ^ Releases any resource held by this response. If the response body
    -- has not been fully read yet, doing so after this call will likely
    -- be impossible.
    --
    -- Since 0.1.0
    , responseOriginalRequest :: Request
    -- ^ Holds original @Request@ related to this @Response@ (with an empty body).
    -- This field is intentionally not exported directly, but made availble
    -- via @getOriginalRequest@ instead.
    --
    -- Since 0.7.8
    }
    deriving (Show, T.Typeable, Functor, Data.Foldable.Foldable, Data.Traversable.Traversable)

-- Purposely not providing this instance.  It used to use 'equivCookieJar'
-- semantics before 0.7.0, but should, if anything, use 'equalCookieJar'
-- semantics.
--
-- instance Exception Eq

newtype ResponseClose = ResponseClose { runResponseClose :: IO () }
    deriving T.Typeable
instance Show ResponseClose where
    show _ = "ResponseClose"

-- | Settings for a @Manager@. Please use the 'defaultManagerSettings' function and then modify
-- individual settings. For more information, see <http://www.yesodweb.com/book/settings-types>.
--
-- Since 0.1.0
data ManagerSettings = ManagerSettings
    { managerConnCount :: Int
      -- ^ Number of connections to a single host to keep alive. Default: 10.
      --
      -- Since 0.1.0
    , managerRawConnection :: IO (Maybe NS.HostAddress -> String -> Int -> IO Connection)
      -- ^ Create an insecure connection.
      --
      -- Since 0.1.0
    , managerTlsConnection :: IO (Maybe NS.HostAddress -> String -> Int -> IO Connection)
      -- ^ Create a TLS connection. Default behavior: throw an exception that TLS is not supported.
      --
      -- Since 0.1.0
    , managerTlsProxyConnection :: IO (S.ByteString -> (Connection -> IO ()) -> String -> Maybe NS.HostAddress -> String -> Int -> IO Connection)
      -- ^ Create a TLS proxy connection. Default behavior: throw an exception that TLS is not supported.
      --
      -- Since 0.2.2
    , managerResponseTimeout :: ResponseTimeout
      -- ^ Default timeout to be applied to requests which do not provide a
      -- timeout value.
      --
      -- Default is 30 seconds
      --
      -- @since 0.5.0
    , managerRetryableException :: SomeException -> Bool
    -- ^ Exceptions for which we should retry our request if we were reusing an
    -- already open connection. In the case of IOExceptions, for example, we
    -- assume that the connection was closed on the server and therefore open a
    -- new one.
    --
    -- Since 0.1.0
    , managerWrapException :: forall a. Request -> IO a -> IO a
    -- ^ Action wrapped around all attempted @Request@s, usually used to wrap
    -- up exceptions in library-specific types.
    --
    -- Default: wrap all @IOException@s in the @InternalException@ constructor.
    --
    -- @since 0.5.0
    , managerIdleConnectionCount :: Int
    -- ^ Total number of idle connection to keep open at a given time.
    --
    -- This limit helps deal with the case where you are making a large number
    -- of connections to different hosts. Without this limit, you could run out
    -- of file descriptors. Additionally, it can be set to zero to prevent
    -- reuse of any connections. Doing this is useful when the server your application
    -- is talking to sits behind a load balancer.
    --
    -- Default: 512
    --
    -- Since 0.3.7
    , managerModifyRequest :: Request -> IO Request
    -- ^ Perform the given modification to a @Request@ before performing it.
    --
    -- This function may be called more than once during request processing.
    -- see https://github.com/snoyberg/http-client/issues/350
    --
    -- Default: no modification
    --
    -- Since 0.4.4
    , managerModifyResponse :: Response BodyReader -> IO (Response BodyReader)
    -- ^ Perform the given modification to a @Response@ after receiving it.
    --
    -- Default: no modification
    --
    -- @since 0.5.5
    , managerProxyInsecure :: ProxyOverride
    -- ^ How HTTP proxy server settings should be discovered.
    --
    -- Default: respect the @proxy@ value on the @Request@ itself.
    --
    -- Since 0.4.7
    , managerProxySecure :: ProxyOverride
    -- ^ How HTTPS proxy server settings should be discovered.
    --
    -- Default: respect the @proxy@ value on the @Request@ itself.
    --
    -- Since 0.4.7
    }
    deriving T.Typeable

-- | How the HTTP proxy server settings should be discovered.
--
-- Since 0.4.7
newtype ProxyOverride = ProxyOverride
    { runProxyOverride :: Bool -> IO (Request -> Request)
    }
    deriving T.Typeable

-- | Keeps track of open connections for keep-alive.
--
-- If possible, you should share a single 'Manager' between multiple threads and requests.
--
-- Since 0.1.0
data Manager = Manager
    { mConns :: KeyedPool ConnKey Connection
    , mResponseTimeout :: ResponseTimeout
    -- ^ Copied from 'managerResponseTimeout'
    , mRetryableException :: SomeException -> Bool
    , mWrapException :: forall a. Request -> IO a -> IO a
    , mModifyRequest :: Request -> IO Request
    , mSetProxy :: Request -> Request
    , mModifyResponse      :: Response BodyReader -> IO (Response BodyReader)
    -- ^ See 'managerProxy'
    }
    deriving T.Typeable

class HasHttpManager a where
    getHttpManager :: a -> Manager
instance HasHttpManager Manager where
    getHttpManager = id

data ConnsMap
    = ManagerClosed
    | ManagerOpen {-# UNPACK #-} !Int !(Map.Map ConnKey (NonEmptyList Connection))

data NonEmptyList a =
    One a UTCTime |
    Cons a Int UTCTime (NonEmptyList a)
    deriving T.Typeable

-- | Hostname or resolved host address.
data ConnHost =
    HostName Text |
    HostAddress NS.HostAddress
    deriving (Eq, Show, Ord, T.Typeable)

-- | @ConnKey@ consists of a hostname, a port and a @Bool@
-- specifying whether to use SSL.
data ConnKey
    = CKRaw (Maybe HostAddress) {-# UNPACK #-} !S.ByteString !Int
    | CKSecure (Maybe HostAddress) {-# UNPACK #-} !S.ByteString !Int
    | CKProxy
        {-# UNPACK #-} !S.ByteString
        !Int

        -- Proxy-Authorization request header
        (Maybe S.ByteString)

        -- ultimate host
        {-# UNPACK #-} !S.ByteString

        -- ultimate port
        !Int
    deriving (Eq, Show, Ord, T.Typeable)

-- | Status of streaming a request body from a file.
--
-- Since 0.4.9
data StreamFileStatus = StreamFileStatus
    { fileSize :: Int64
    , readSoFar :: Int64
    , thisChunkSize :: Int
    }
    deriving (Eq, Show, Ord, T.Typeable)

-- | Hooks for tracing client behaviour across a request
--
-- @since 0.7.10
data RequestTrace = RequestTrace
  { getConnection :: NS.HostName -> NS.PortNumber -> IO ()
  -- ^ GetConn is called before a connection is created or
  -- retrieved from an idle pool. The hostPort is the
  -- "host:port" of the target or proxy. getConnection is called even
  -- if there's already an idle cached connection available.
  , gotConnection :: GotConnectionInfo -> IO ()
  -- ^ GotConn is called after a successful connection is
  -- obtained. There is no hook for failure to obtain a
  -- connection; instead, use the error from
  -- Transport.RoundTrip.
  , putIdleConnection :: Maybe SomeException -> IO ()
  --	PutIdleConn is called when the connection is returned to
  -- the idle pool. If err is nil, the connection was
  -- successfully returned to the idle pool. If err is non-nil,
  -- it describes why not. PutIdleConn is not called if
  -- connection reuse is disabled via Transport.DisableKeepAlives.
  -- PutIdleConn is called before the caller's Response.Body.Close
  -- call returns.
  -- For HTTP/2, this hook is not currently used.
  , gotFirstResponseByte :: IO ()
  -- ^ GotFirstResponseByte is called when the first byte of the response
  -- headers is available.
  , got100Continue :: IO ()
  -- ^ Got100Continue is called if the server replies with a "100
  -- Continue" response.
  , got1xxResponse :: Status -> ResponseHeaders -> IO (Maybe SomeException)
  -- ^ Got1xxResponse is called for each 1xx informational response header
  -- returned before the final non-1xx response. Got1xxResponse is called
  -- for "100 Continue" responses, even if Got100Continue is also defined.
  -- If it returns an error, the client request is aborted with that error value.
  , dnsStart :: DNSStartInfo -> IO ()
  -- ^ DNSStart is called when a DNS lookup begins.
  , dnsDone :: DNSDoneInfo -> IO ()
  -- ^ DNSDone is called when a DNS lookup ends.
  , connectStart :: String -> String -> IO ()
  -- ^ ConnectStart is called when a new connection's Dial begins.
  -- This may be called multiple times.
  , connectDone :: String -> String -> Maybe SomeException -> IO ()
  -- ^ ConnectDone is called when a new connection's Dial
  -- completes. The provided err indicates whether the
  -- connection completed successfully.
  -- If net.Dialer.DualStack ("Happy Eyeballs") support is
  -- enabled, this may be called multiple times.
  , tlsHandshakeStart :: IO ()
  -- ^ TLSHandshakeStart is called when the TLS handshake is started. When
  -- connecting to an HTTPS site via an HTTP proxy, the handshake happens
  -- after the CONNECT request is processed by the proxy.
  -- TODO TLS state depends on impl?
  , tlsHandshakeDone :: () -> IO ()
  -- ^ TLSHandshakeDone is called after the TLS handshake with either the
  -- successful handshake's connection state, or a non-nil error on handshake
  -- failure.
  , wroteHeaderField :: [(ByteString, [ByteString])] -> IO ()
  -- ^ WroteHeaderField is called after the Transport has written
  -- each request header. At the time of this call the values
  -- might be buffered and not yet written to the network.
  , wroteHeaders :: IO ()
  -- ^ WroteHeaders is called after the Transport has written
  -- all request headers.
  , wait100Continue :: IO ()
  -- ^ Wait100Continue is called if the Request specified
  -- "Expect: 100-continue" and the Transport has written the
  -- request headers but is waiting for "100 Continue" from the
  -- server before writing the request body.
  , wroteRequest :: WroteRequestInfo -> IO ()
  -- ^ WroteRequest is called with the result of writing the
  -- request and any body. It may be called multiple times
  -- in the case of retried requests.
  }

data GotConnectionInfo = GotConnectionInfo
  { connection :: Connection
  , reused :: Bool
  , idleTime :: Maybe UTCTime
  }

newtype DNSStartInfo = DNSStartInfo 
  { domain :: String
  }

data DNSDoneInfo 
  = DNSDoneAddresses [NS.AddrInfo]
  | DNSDoneError SomeException

newtype WroteRequestInfo = WroteRequestInfo
  { requestWriteError :: Maybe SomeException
  }
