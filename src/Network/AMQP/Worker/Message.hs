{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Network.AMQP.Worker.Message where

import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Base (liftBase)
import Data.Aeson (ToJSON, FromJSON)
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)
import Network.AMQP (newMsg, DeliveryMode(..), Ack(..))
import qualified Network.AMQP as AMQP

import Network.AMQP.Worker.Key (Key, Routing, keyText)
import Network.AMQP.Worker.Poll (poll)
import Network.AMQP.Worker.Connection (Connection, withChannel)
import Network.AMQP.Worker.Queue (Queue(..))
import Network.AMQP.Worker.Exchange (Exchange(..), ExchangeName) 

-- types --------------------------

-- | a parsed message from the queue
data Message a = Message
  { body :: ByteString
  , value :: a
  } deriving (Show, Eq)


data ConsumeResult a
  = Parsed (Message a)
  | Error ParseError

data ParseError = ParseError String ByteString

type Microseconds = Int


jsonMessage :: ToJSON a => a -> AMQP.Message
jsonMessage a = newMsg
  { AMQP.msgBody = Aeson.encode a
  , AMQP.msgContentType = Just "application/json"
  , AMQP.msgContentEncoding = Just "UTF-8"
  , AMQP.msgDeliveryMode = Just Persistent
  }



-- | publish a message to a routing key, without making sure a queue exists to handle it or if it is the right type of message body
--
-- > publishToExchange conn "users.admin.created" (User "username")
publishToExchange :: (ToJSON a, MonadBaseControl IO m) => Connection -> ExchangeName -> Key Routing a -> a -> m ()
publishToExchange conn exg rk msg =
  withChannel conn $ \chan -> liftBase $ do
    _ <- AMQP.publishMsg chan exg (keyText rk) (jsonMessage msg)
    return ()


-- | send a message to a queue. Enforces that the message type and queue name are correct at the type level
--
-- > let queue = Worker.queue exchange "users" :: Queue User
-- > send conn queue (User "username")
send :: (ToJSON msg, MonadBaseControl IO m) => Connection -> Exchange -> Key Routing msg -> msg -> m ()
send conn (Exchange exg) key =
  publishToExchange conn exg key


-- | Check for a message once and attempt to parse it
--
-- > res <- consume conn queue
-- > case res of
-- >   Just (Parsed m) -> print m
-- >   Just (Error e) -> putStrLn "could not parse message"
-- >   Notihng -> putStrLn "No messages on the queue"
consume :: (FromJSON msg, MonadBaseControl IO m) => Connection -> Queue msg -> m (Maybe (ConsumeResult msg))
consume conn (Queue _ name) = do
  mme <- withChannel conn $ \chan -> do
    m <- liftBase $ AMQP.getMsg chan Ack name
    pure m

  case mme of
    Nothing ->
      return Nothing

    Just (msg, env) -> do
      liftBase $ AMQP.ackEnv env
      let bd = AMQP.msgBody msg
      case Aeson.eitherDecode bd of
        Left err ->
          return $ Just $ Error (ParseError err bd)

        Right v ->
          return $ Just $ Parsed (Message bd v)



-- | Block while checking for messages every N microseconds. Return once you find one.
--
-- > res <- consumeNext conn queue
-- > case res of
-- >   (Parsed m) -> print m
-- >   (Error e) -> putStrLn "could not parse message"
consumeNext :: (FromJSON msg, MonadBaseControl IO m) => Microseconds -> Connection -> Queue msg -> m (ConsumeResult msg)
consumeNext pd conn key =
    poll pd $ consume conn key
