module Hasql.Private.Decoders.Result where

import Hasql.Private.Prelude hiding (maybe, many)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import qualified Hasql.Private.Decoders.Row as Row
import qualified Data.Attoparsec.ByteString.Char8 as Attoparsec
import qualified Data.ByteString as ByteString
import qualified Hasql.Private.Prelude as Prelude
import qualified Data.Vector as Vector
import qualified Data.Vector.Mutable as MutableVector


newtype Result a =
  Result (ReaderT (Bool, LibPQ.Result) (ExceptT Error IO) a)
  deriving (Functor, Applicative, Monad)

data Error =
  -- | 
  -- An error reported by the DB. Code, message, details, hint.
  -- 
  -- * The SQLSTATE code for the error. The SQLSTATE code identifies the type of error that has occurred; 
  -- it can be used by front-end applications to perform specific operations (such as error handling) 
  -- in response to a particular database error. 
  -- For a list of the possible SQLSTATE codes, see Appendix A.
  -- This field is not localizable, and is always present.
  -- 
  -- * The primary human-readable error message (typically one line). Always present.
  -- 
  -- * Detail: an optional secondary error message carrying more detail about the problem. 
  -- Might run to multiple lines.
  -- 
  -- * Hint: an optional suggestion what to do about the problem. 
  -- This is intended to differ from detail in that it offers advice (potentially inappropriate) 
  -- rather than hard facts. Might run to multiple lines.
  ServerError !ByteString !ByteString !(Maybe ByteString) !(Maybe ByteString) |
  -- |
  -- The database returned an unexpected result.
  -- Indicates an improper statement or a schema mismatch.
  UnexpectedResult !Text |
  -- |
  -- An error of the row reader, preceded by the index of the row.
  RowError !Int !Row.Error |
  -- |
  -- An unexpected amount of rows.
  UnexpectedAmountOfRows !Int
  deriving (Show)

{-# INLINE run #-}
run :: Result a -> (Bool, LibPQ.Result) -> IO (Either Error a)
run (Result reader) env =
  runExceptT (runReaderT reader env)

{-# INLINE unit #-}
unit :: Result ()
unit =
  checkExecStatus $ \case
    LibPQ.CommandOk -> True
    LibPQ.TuplesOk -> True
    _ -> False

{-# INLINE rowsAffected #-}
rowsAffected :: Result Int64
rowsAffected =
  do
    checkExecStatus $ \case
      LibPQ.CommandOk -> True
      _ -> False
    Result $ ReaderT $ \(_, result) -> ExceptT $
      LibPQ.cmdTuples result & fmap cmdTuplesReader
  where
    cmdTuplesReader =
      notNothing >=> notEmpty >=> decimal
      where
        notNothing =
          Prelude.maybe (Left (UnexpectedResult "No bytes")) Right
        notEmpty bytes =
          if ByteString.null bytes
            then Left (UnexpectedResult "Empty bytes")
            else Right bytes
        decimal bytes =
          mapLeft (\m -> UnexpectedResult ("Decimal parsing failure: " <> fromString m)) $
          Attoparsec.parseOnly (Attoparsec.decimal <* Attoparsec.endOfInput) bytes

{-# INLINE checkExecStatus #-}
checkExecStatus :: (LibPQ.ExecStatus -> Bool) -> Result ()
checkExecStatus predicate =
  {-# SCC "checkExecStatus" #-} 
  do
    status <- Result $ ReaderT $ \(_, result) -> lift $ LibPQ.resultStatus result
    unless (predicate status) $ do
      case status of
        LibPQ.BadResponse   -> serverError
        LibPQ.NonfatalError -> serverError
        LibPQ.FatalError    -> serverError
        _ -> Result $ lift $ ExceptT $ pure $ Left $ UnexpectedResult $ "Unexpected result status: " <> (fromString $ show status)

{-# INLINE serverError #-}
serverError :: Result ()
serverError =
  Result $ ReaderT $ \(_, result) -> ExceptT $ do
    code <- 
      fmap (fromMaybe ($bug "No code")) $
      LibPQ.resultErrorField result LibPQ.DiagSqlstate
    message <- 
      fmap (fromMaybe ($bug "No message")) $
      LibPQ.resultErrorField result LibPQ.DiagMessagePrimary
    detail <- 
      LibPQ.resultErrorField result LibPQ.DiagMessageDetail
    hint <- 
      LibPQ.resultErrorField result LibPQ.DiagMessageHint
    pure $ Left $ ServerError code message detail hint

{-# INLINE maybe #-}
maybe :: Row.Row a -> Result (Maybe a)
maybe rowDec =
  do
    checkExecStatus $ \case
      LibPQ.TuplesOk -> True
      _ -> False
    Result $ ReaderT $ \(integerDatetimes, result) -> ExceptT $ do
      maxRows <- LibPQ.ntuples result
      case maxRows of
        0 -> return (Right Nothing)
        1 -> do
          maxCols <- LibPQ.nfields result
          fmap (fmap Just . mapLeft (RowError 0)) $ Row.run rowDec (result, 0, maxCols, integerDatetimes)
        _ -> return (Left (UnexpectedAmountOfRows (rowToInt maxRows)))
  where
    rowToInt (LibPQ.Row n) =
      fromIntegral n
    intToRow =
      LibPQ.Row . fromIntegral

{-# INLINE single #-}
single :: Row.Row a -> Result a
single rowDec =
  do
    checkExecStatus $ \case
      LibPQ.TuplesOk -> True
      _ -> False
    Result $ ReaderT $ \(integerDatetimes, result) -> ExceptT $ do
      maxRows <- LibPQ.ntuples result
      case maxRows of
        1 -> do
          maxCols <- LibPQ.nfields result
          fmap (mapLeft (RowError 0)) $ Row.run rowDec (result, 0, maxCols, integerDatetimes)
        _ -> return (Left (UnexpectedAmountOfRows (rowToInt maxRows)))
  where
    rowToInt (LibPQ.Row n) =
      fromIntegral n
    intToRow =
      LibPQ.Row . fromIntegral

{-# INLINE vector #-}
vector :: Row.Row a -> Result (Vector a)
vector rowDec =
  do
    checkExecStatus $ \case
      LibPQ.TuplesOk -> True
      _ -> False
    Result $ ReaderT $ \(integerDatetimes, result) -> ExceptT $ do
      maxRows <- LibPQ.ntuples result
      maxCols <- LibPQ.nfields result
      mvector <- MutableVector.unsafeNew (rowToInt maxRows)
      failureRef <- newIORef Nothing
      forMFromZero_ (rowToInt maxRows) $ \rowIndex -> do
        rowResult <- Row.run rowDec (result, intToRow rowIndex, maxCols, integerDatetimes)
        case rowResult of
          Left !x -> writeIORef failureRef (Just (RowError rowIndex x))
          Right !x -> MutableVector.unsafeWrite mvector rowIndex x
      readIORef failureRef >>= \case
        Nothing -> Right <$> Vector.unsafeFreeze mvector
        Just x -> pure (Left x)
  where
    rowToInt (LibPQ.Row n) =
      fromIntegral n
    intToRow =
      LibPQ.Row . fromIntegral

{-# INLINE foldl #-}
foldl :: (a -> b -> a) -> a -> Row.Row b -> Result a
foldl step init rowDec =
  {-# SCC "foldl" #-} 
  do
    checkExecStatus $ \case
      LibPQ.TuplesOk -> True
      _ -> False
    Result $ ReaderT $ \(integerDatetimes, result) -> ExceptT $ {-# SCC "traversal" #-} do
      maxRows <- LibPQ.ntuples result
      maxCols <- LibPQ.nfields result
      accRef <- newIORef init
      failureRef <- newIORef Nothing
      forMFromZero_ (rowToInt maxRows) $ \rowIndex -> do
        rowResult <- Row.run rowDec (result, intToRow rowIndex, maxCols, integerDatetimes)
        case rowResult of
          Left !x -> writeIORef failureRef (Just (RowError rowIndex x))
          Right !x -> modifyIORef accRef (\acc -> step acc x)
      readIORef failureRef >>= \case
        Nothing -> Right <$> readIORef accRef
        Just x -> pure (Left x)
  where
    rowToInt (LibPQ.Row n) =
      fromIntegral n
    intToRow =
      LibPQ.Row . fromIntegral

{-# INLINE foldr #-}
foldr :: (b -> a -> a) -> a -> Row.Row b -> Result a
foldr step init rowDec =
  {-# SCC "foldr" #-} 
  do
    checkExecStatus $ \case
      LibPQ.TuplesOk -> True
      _ -> False
    Result $ ReaderT $ \(integerDatetimes, result) -> ExceptT $ do
      maxRows <- LibPQ.ntuples result
      maxCols <- LibPQ.nfields result
      accRef <- newIORef init
      failureRef <- newIORef Nothing
      forMToZero_ (rowToInt maxRows) $ \rowIndex -> do
        rowResult <- Row.run rowDec (result, intToRow rowIndex, maxCols, integerDatetimes)
        case rowResult of
          Left !x -> writeIORef failureRef (Just (RowError rowIndex x))
          Right !x -> modifyIORef accRef (\acc -> step x acc)
      readIORef failureRef >>= \case
        Nothing -> Right <$> readIORef accRef
        Just x -> pure (Left x)
  where
    rowToInt (LibPQ.Row n) =
      fromIntegral n
    intToRow =
      LibPQ.Row . fromIntegral
