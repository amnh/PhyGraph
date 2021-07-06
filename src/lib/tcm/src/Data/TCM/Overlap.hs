-----------------------------------------------------------------------------
-- |
-- Module      :  Bio.Metadata.Dynamic.Internal
-- Copyright   :  (c) 2015-2021 Ward Wheeler
-- License     :  BSD-style
--
-- Maintainer  :  wheeler@amnh.org
-- Stability   :  provisional
-- Portability :  portable
--
-----------------------------------------------------------------------------

{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE DeriveAnyClass         #-}
{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE DerivingStrategies     #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MagicHash              #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE StrictData             #-}
{-# LANGUAGE TypeFamilies           #-}
{-# LANGUAGE UnboxedTuples          #-}

module Data.TCM.Overlap
  ( overlap
  , overlap2
  , overlap3
  ) where

import Data.Bits
import Data.Foldable.Custom
import Data.List.NonEmpty      (NonEmpty(..))
import Data.Semigroup
import Data.Semigroup.Foldable
import Data.Word


-- |
-- Takes one or more elements of 'FiniteBits' and a symbol change cost function
-- and returns a tuple of a new character, along with the cost of obtaining that
-- character. The return character may be (or is even likely to be) ambiguous.
-- Will attempt to intersect the two characters, but will union them if that is
-- not possible, based on the symbol change cost function.
--
-- To clarify, the return character is an intersection of all possible least-cost
-- combinations, so for instance, if @ char1 == A,T @ and @ char2 == G,C @, and
-- the two (non-overlapping) least cost pairs are A,C and T,G, then the return
-- value is A,C,G,T.
{-# INLINE overlap #-}
{-# SPECIALISE overlap :: FiniteBits e => (Word -> Word -> Word) -> NonEmpty e -> (e, Word) #-}
{-# SPECIALISE overlap :: (Word -> Word -> Word) -> NonEmpty Word   -> (Word  , Word) #-}
{-# SPECIALISE overlap :: (Word -> Word -> Word) -> NonEmpty Word8  -> (Word8 , Word) #-}
{-# SPECIALISE overlap :: (Word -> Word -> Word) -> NonEmpty Word16 -> (Word16, Word) #-}
{-# SPECIALISE overlap :: (Word -> Word -> Word) -> NonEmpty Word32 -> (Word32, Word) #-}
{-# SPECIALISE overlap :: (Word -> Word -> Word) -> NonEmpty Word64 -> (Word64, Word) #-}
overlap
  :: ( FiniteBits e
     , Foldable1 f
     , Functor f
     )
  => (Word -> Word -> Word) -- ^ Symbol change matrix (SCM) to determine cost
  -> f e                    -- ^ List of elements for of which to find the k-median and cost
  -> (e, Word)              -- ^ K-median and cost
overlap sigma xs = go size maxBound zero
  where
    (size, zero) = let wlog = getFirst $ foldMap1 First xs
                   in  (finiteBitSize wlog, wlog `xor` wlog)

    go 0 theCost bits = (bits, theCost)
    go i oldCost bits =
        let i' = i - 1
            newCost = sum' $ getDistance (toEnum i') <$> xs
            (minCost, bits') = case oldCost `compare` newCost of
                                 EQ -> (oldCost, bits `setBit` i')
                                 LT -> (oldCost, bits            )
                                 GT -> (newCost, zero `setBit` i')
        in go i' minCost bits'

    getDistance :: (FiniteBits e, Show e) => Word -> e -> Word
    getDistance i b = go' size (maxBound :: Word)
      where
        go' :: Int -> Word -> Word
        go' 0 a = a
        go' j a =
          let j' = j - 1
              a' = if b `testBit` j' then min a $ sigma i (toEnum j') else a
          in  go' j' a'


-- |
-- Calculate the median between /two/ states.
{-# INLINE     overlap2 #-}
{-# SPECIALISE overlap2 :: (Word -> Word -> Word) -> Word   -> Word   -> (Word  , Word) #-}
{-# SPECIALISE overlap2 :: (Word -> Word -> Word) -> Word8  -> Word8  -> (Word8 , Word) #-}
{-# SPECIALISE overlap2 :: (Word -> Word -> Word) -> Word16 -> Word16 -> (Word16, Word) #-}
{-# SPECIALISE overlap2 :: (Word -> Word -> Word) -> Word32 -> Word32 -> (Word32, Word) #-}
{-# SPECIALISE overlap2 :: (Word -> Word -> Word) -> Word64 -> Word64 -> (Word64, Word) #-}
overlap2
  :: FiniteBits e
  => (Word -> Word -> Word)
  -> e
  -> e
  -> (e, Word)
overlap2 sigma char1 char2 = overlap sigma $ char1 :| [char2]


-- |
-- Calculate the median between /three/ states.
{-# INLINE     overlap3 #-}
{-# SPECIALISE overlap3 :: (Word -> Word -> Word) -> Word   -> Word   -> Word   -> (Word  , Word) #-}
{-# SPECIALISE overlap3 :: (Word -> Word -> Word) -> Word8  -> Word8  -> Word8  -> (Word8 , Word) #-}
{-# SPECIALISE overlap3 :: (Word -> Word -> Word) -> Word16 -> Word16 -> Word16 -> (Word16, Word) #-}
{-# SPECIALISE overlap3 :: (Word -> Word -> Word) -> Word32 -> Word32 -> Word32 -> (Word32, Word) #-}
{-# SPECIALISE overlap3 :: (Word -> Word -> Word) -> Word64 -> Word64 -> Word64 -> (Word64, Word) #-}
overlap3
  :: FiniteBits e
  => (Word -> Word -> Word)
  -> e
  -> e
  -> e
  -> (e, Word)
overlap3 sigma char1 char2 char3 = overlap sigma $ char1 :| [char2, char3]
