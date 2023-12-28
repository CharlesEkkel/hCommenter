module Server (app, swaggerDefinition) where

import           ClassyPrelude              hiding (Handler)
import           Control.Lens               ((&), (.~))
import           Control.Monad.Trans.Except (except)
import qualified Data.Aeson                 as JSON
import           Data.Aeson.Encode.Pretty   (encodePretty)
import           Data.Bifoldable            (bitraverse_)
import qualified Data.ByteString.Lazy.Char8 as BS8 (ByteString)
import           Data.Either.Extra          (mapLeft)
import           Data.Swagger               (HasInfo (info), HasTitle (title))
import           Database.Interface         (CommentStorage)
import           Database.Mockserver        (mockComments)
import           Database.PureStorage       (runCommentStoragePure)
import           Database.StorageTypes
import           Effectful                  (Eff, IOE, runEff, (:>))
import           Effectful.Error.Static     (CallStack, Error, prettyCallStack,
                                             runError, runErrorWith)
import           Handlers.Comment           (CommentsAPI,
                                             InputError (BadArgument),
                                             commentServer)
import           Handlers.Reply             (ReplyAPI, replyServer)
import           Handlers.Voting            (VotingAPI, votingServer)
import           Katip                      (Verbosity (V0), showLS)
import           Logging                    (Log, getConsoleScribe, logError,
                                             logExceptions, runLog)
import           Servant                    (Application, Handler (Handler),
                                             Proxy (..), Server,
                                             ServerError (errBody, errHTTPCode, errHeaders),
                                             err404, hoistServer, serve,
                                             type (:<|>) (..))
import           Servant.Swagger            (HasSwagger (toSwagger))
import qualified ServerTypes                as T

type API = CommentsAPI :<|> ReplyAPI :<|> VotingAPI

swaggerDefinition :: BS8.ByteString
swaggerDefinition =
  encodePretty $ toSwagger (Proxy :: Proxy API)
    & info.title .~ "hCommenter API"

serverAPI :: Server API
serverAPI = do
  hoistServer fullAPI effToHandler $
    commentServer :<|> replyServer :<|> votingServer

fullAPI :: Proxy API
fullAPI = Proxy

app :: Application
app = serve fullAPI serverAPI

effToHandler :: Eff [CommentStorage, Error InputError, Error StorageError, Log, IOE] a -> Handler a
effToHandler m = do
  scribe <- liftIO $ getConsoleScribe V0
  result <- liftIO $ runEff
            . runLog "hCommenter-API" "Dev" "Console" scribe
            . logExceptions
            . logExplicitErrors
            . runError @StorageError
            . runErrorWith (\_ (BadArgument err) -> error $ unpack err)
            . runCommentStoragePure mockComments
            $ m
  Handler $ except $ mapLeft toServerError result
  where
    toServerError = \case
      (callStack, CommentNotFound) -> servantErrorWithText err404 $ "Can't find the comment" <> tshow callStack

logExplicitErrors :: (Show e, Log :> es) => Eff es (Either (CallStack, e) a) -> Eff es (Either (CallStack, e) a)
logExplicitErrors currEff = do
  value <- currEff
  bitraverse_ handleLeft pure value
  pure value

  where
    handleLeft (callStack, err) = do
      logError $ "Custom error '" <> showLS err <> "' with callstack: " <> showLS (prettyCallStack callStack)

servantErrorWithText ::
  ServerError ->
  Text ->
  ServerError
servantErrorWithText sErr msg =
  sErr
    { errBody = errorBody (errHTTPCode sErr),
      errHeaders = [jsonHeaders]
    }
  where
    errorBody code = JSON.encode $ T.Error msg code

    jsonHeaders =
      (fromString "Content-Type", "application/json;charset=utf-8")
