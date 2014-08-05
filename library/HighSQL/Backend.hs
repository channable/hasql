-- |
-- An open API for implementation of specific backend drivers.
module HighSQL.Backend where

import HighSQL.Prelude hiding (Error)
import qualified Data.Text as Text
import qualified Language.Haskell.TH as TH


data Backend =
  Backend {
    connect :: IO Connection
  }


data Connection =
  forall s. 
  Connection {
    -- |
    -- Start a transaction in a write mode if the flag is true.
    beginTransaction :: Bool -> IO (),
    -- |
    -- Finish the transaction, 
    -- while releasing all the resources acquired with 'executeAndStream'.
    -- 
    -- The boolean defines whether to commit the updates,
    -- otherwise it rolls back.
    finishTransaction :: Bool -> IO (),
    -- |
    -- If the backend supports statement preparation,
    -- this function sompiles a bytestring statement 
    -- with placeholders if it's not compiled already,
    -- and otherwise returns the cached statement. 
    -- IOW, implements memoization.
    -- 
    -- If the backend does not support this,
    -- then this function should simply be implemented as a 'return'.
    prepare :: ByteString -> IO s,
    -- |
    -- Execute a statement with values for placeholders.
    execute :: s -> [Value] -> IO (),
    -- |
    -- Execute a statement with values for placeholders,
    -- returning the amount of affected rows.
    executeCountingEffects :: s -> [Value] -> IO Integer,
    -- |
    -- Execute a statement with values for placeholders,
    -- returning the possibly generated auto-incremented value.
    executeIncrementing :: s -> [Value] -> IO (Maybe Integer),
    -- |
    -- Execute a statement with values and an expected results stream size.
    -- The expected stream size can be used by the backend to determine 
    -- an optimal fetching method.
    executeStreaming :: s -> [Value] -> Maybe Integer -> IO ResultSet,
    -- |
    -- Close the connection.
    disconnect :: IO ()
  }


data Error =
  -- |
  -- A transaction failed and should be retried.
  TransactionError |
  -- |
  -- Cannot connect to a server 
  -- or the connection got interrupted.
  ConnectionError Text |
  -- |
  -- A free-form backend-specific exception.
  BackendError SomeException
  deriving (Show, Typeable)

instance Exception Error


-- |
-- A row width and a stream of values.
-- The length of the stream must be a multiple of the row width.
type ResultSet =
  (Int, ListT IO Value)


-- * Value
-------------------------

data Value =
  Value_Text !Text |
  Value_ByteString !ByteString |
  Value_Word32 !Word32 |
  Value_Word64 !Word64 |
  Value_Int32 !Int32 |
  Value_Int64 !Int64 |
  Value_Integer !Integer |
  Value_Char !Char |
  Value_Bool !Bool |
  Value_Double !Double |
  Value_Rational !Rational |
  Value_Day !Day |
  Value_LocalTime !LocalTime |
  Value_TimeOfDay !TimeOfDay |
  Value_ZonedTime !ZonedTime |
  Value_UTCTime !UTCTime |
  Value_NominalDiffTime !NominalDiffTime |
  -- | Yes, this encodes @NULL@s.
  Value_Maybe !(Maybe Value)
  deriving (Show, Data, Typeable, Generic)
