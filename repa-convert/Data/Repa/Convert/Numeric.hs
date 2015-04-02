
module Data.Repa.Convert.Numeric
        ( -- * Int conversion
          readIntBuf
        , readIntWith#
        , showIntBuf

          -- * Double conversion
        , readDoubleBuf
        , showDoubleShortestBuf 
        , showDoubleFixedBuf)
where
import Data.Word
import Data.Char
import GHC.Exts

import qualified Data.ByteString.Internal               as BS
import qualified Data.Double.Conversion.ByteString      as DC

import qualified Foreign.Ptr                            as F
import qualified Foreign.ForeignPtr                     as F
import qualified Foreign.Storable                       as F
import qualified Foreign.Marshal.Alloc                  as F
import qualified Foreign.Marshal.Utils                  as F


-- Int --------------------------------------------------------------------------------------------
-- | Try to read an `Int` from the front of the given buffer.
readIntBuf 
        :: Ptr Word8                    -- ^ Buffer holding digits.
        -> Int                          -- ^ Length of buffer.
        -> IO (Maybe (Int, Int))        -- ^ Int read, and length of digits.
 
readIntBuf ptr (I# len)
 = case readIntBuf# ptr len of
        (# 0#, _, _  #) -> return $ Nothing
        (# _,  n, ix #) -> return $ Just (I# n, I# ix)
{-# INLINE readIntBuf #-}


-- | Specialise readIntWith# to foreign buffers.
readIntBuf#
        :: Ptr Word8                    -- ^ Buffer holding digits.
        -> Int#                         -- ^ Length of buffer.
        -> (# Int#, Int#, Int# #)       -- ^ Convert success?, value, length read.

readIntBuf# buf len
 = let peek8 ix
         = case BS.inlinePerformIO (F.peekByteOff buf (I# ix)) of
                (w8 :: Word8) -> case fromIntegral w8 of
                                        I# i    -> i
       {-# INLINE peek8 #-}

   in  readIntWith# peek8 len
{-# NOINLINE readIntBuf# #-}


-- | Read an integer from an abstract buffer.
readIntWith# 
        :: (Int# -> Int#)               -- ^ Function to get a byte from the source.
        -> Int#                         -- ^ Length of buffer
        -> (# Int#, Int#, Int# #)       -- ^ Convert success?, value, length read.

readIntWith# !get len
 = start 0#
 where
        start !ix
         | 1# <- ix >=# len = (# 0#, 0#, 0# #)
         | otherwise        = sign ix

        -- Check for explicit sign character,
        -- and encode what it was as an integer.
        sign !ix
         | !s   <- get 0#
         = case chr $ fromIntegral (I# s) of
                '-'     -> loop 1# (ix +# 1#) 0#
                '+'     -> loop 2# (ix +# 1#) 0#
                _       -> loop 0#  ix        0#

        loop !neg !ix !n 
         -- We've hit the end of the array.
         | 1# <- ix >=# len   
         = end neg ix n

         | otherwise
         = case get ix of
               -- Current character is a digit, so add it to the accmulator.
             w | 1# <- w >=# 0x30# 
               , 1# <- w <=# 0x039#
               -> loop neg ( ix +# 1#) 
                           ((n  *# 10#) +# (w -# 0x30#))

               -- Current character is not a digit.
               | otherwise
               -> end neg ix n

        end !neg !ix !n
         -- We didn't find any digits, and there was no explicit sign.
         | 1# <- ix  ==# 0#
         , 1# <- neg ==# 0#
         = (# 0#, 0#, 0# #)

         -- We didn't find any digits, but there was an explicit sign.
         | 1# <- ix  ==# 1#
         , 1# <- neg /=# 0#
         = (# 0#, 0#, 0# #)

         -- Number was explicitly negated.
         | 1# <- neg ==# 1#                    
         , I# n'        <- negate (I# n)
         = (# 1#, n', ix #)

         -- Number was not negated.
         | otherwise
         = (# 1#, n, ix #)
{-# INLINE readIntWith# #-}


-- | Show an `Int` as an ASCII string, allocating a new buffer.
showIntBuf :: Int -> IO (F.ForeignPtr Word8)
showIntBuf i
 = case DC.toFixed 0 (fromIntegral i) of
        BS.PS p _ _     -> return p
{-# INLINE showIntBuf #-}


-- Double -----------------------------------------------------------------------------------------
-- | Read a double from a foreign buffer.
-- 
--   The whole buffer of the given length contains the ASCII
--   representation of the double.
--
readDoubleBuf :: Ptr Word8 -> Int -> IO (Double, Int)
readDoubleBuf pIn len
 = F.allocaBytes (len + 1) $ \pBuf ->
   F.alloca                $ \pRes ->
    do
        -- Copy the data to our new buffer.
        F.copyBytes pBuf pIn (fromIntegral len)

        -- Poke a 0 on the end to ensure it's null terminated.
        F.pokeByteOff pBuf len (0 :: Word8)

        -- Call the C strtod function
        let !d  = strtod pBuf pRes

        -- Read back the end pointer.
        res     <- F.peek pRes

        return (d, res `F.minusPtr` pBuf)
{-# INLINE readDoubleBuf #-}


-- TODO: strtod will skip whitespace before the actual double, 
-- but we probably want to avoid this to be consistent.
foreign import ccall unsafe
 strtod :: Ptr Word8 -> Ptr (Ptr Word8) -> Double



-- | Show a `Double` as an ASCII string, 
--   yielding a freshly allocated buffer and its length.
--
--   * The value is printed as either (sign)digits.digits,
--     or in exponential format, depending on which is shorted.
--
--   * The result is buffer not null terminated.
--
showDoubleShortestBuf :: Double -> IO (F.ForeignPtr Word8, Int)
showDoubleShortestBuf d
 = case DC.toShortest d of
        BS.PS p _ n  -> return (p, n)
{-# INLINE showDoubleShortestBuf #-}


-- | Like `showDoubleShortestBuf`, but use a fixed number of digits after
--   the decimal point.
showDoubleFixedBuf :: Int -> Double -> IO (F.ForeignPtr Word8, Int)
showDoubleFixedBuf !prec !d
 = case DC.toFixed prec d of
        BS.PS p _ n  -> return (p, n)
{-# INLINE showDoubleFixedBuf #-}

