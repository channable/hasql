module Hasql.Settings where

import Hasql.Prelude
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy.Builder as BB
import qualified Data.ByteString.Lazy.Builder.ASCII as BB
import qualified Data.ByteString.Lazy as BL


-- |
-- Connection settings.
data Settings =
  -- | 
  -- A host, a port, a user, a password and a database.
  ParametricSettings ByteString Word16 ByteString ByteString ByteString |
  -- | 
  -- All settings encoded in a single byte string according to 
  -- <http://www.postgresql.org/docs/9.4/static/libpq-connect.html#LIBPQ-CONNSTRING the PostgreSQL format>.
  RawSettings ByteString
  deriving (Show)

{-# INLINE asBytes #-}
asBytes :: Settings -> ByteString
asBytes =
  \case
    ParametricSettings host port user password database ->
      BL.toStrict $ BB.toLazyByteString $ mconcat $ intersperse (BB.char7 ' ') $ catMaybes $
      [
        mappend (BB.string7 "host=") . BB.byteString <$> 
        mfilter (not . B.null) (pure host)
        ,
        mappend (BB.string7 "port=") . BB.word16Dec <$> 
        mfilter (/= 0) (pure port)
        ,
        mappend (BB.string7 "user=") . BB.byteString <$> 
        mfilter (not . B.null) (pure user)
        ,
        mappend (BB.string7 "password=") . BB.byteString <$> 
        mfilter (not . B.null) (pure password)
        ,
        mappend (BB.string7 "dbname=") . BB.byteString <$> 
        mfilter (not . B.null) (pure database)
      ]
    RawSettings bytes ->
      bytes

