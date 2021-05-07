module DOLargeFFI where

import Analysis.Parsimony.Dynamic.DirectOptimization.Pairwise
import Bio.Character.Encodable
import Data.Alphabet
import Data.Foldable
import Data.MetricRepresentation
import qualified Data.TCM as TCM
import Data.TCM.Memoized
import qualified Data.BitVector as BV
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Vector (Vector, (!))
import qualified Data.Vector as V
import qualified SymMatrix as SM

import Debug.Trace

{-
  => OverlapFunction (Subcomponent (Element s))
  -> s
  -> s
  -> (Word, s)
-}

wrapperPCG_DO_Large :: Vector BV.BV -> Vector BV.BV -> Vector (Vector Int) -> (Vector BV.BV, Int)
wrapperPCG_DO_Large lhs rhs tcmVect = (resultingMedians, fromEnum resultCost)
    where
        (resultCost, resultFFI) = unboxedUkkonenFullSpaceDO (retreivePairwiseTCM tcmMemo) lhsDC rhsDC

        bitStreams = decodeStream arbitraryAlphabet resultFFI

        resultingMedians = V.fromList . toList $ fmap (BV.fromBits . g 0 . toList) bitStreams

        lhsDC = buildDC lhs 
        rhsDC = buildDC rhs

        tcmMemo = 
            let scm i j         = toEnum . fromEnum $ tcm TCM.! (fromEnum i, fromEnum j)
                sigma i j       = toEnum . fromEnum $ tcm TCM.! (fromEnum i, fromEnum j)
                memoMatrixValue = generateMemoizedTransitionCostMatrix (toEnum $ length arbitraryAlphabet) sigma
            in  ExplicitLayout tcm (getMedianAndCost2D memoMatrixValue)

        (weight, tcm) = TCM.fromRows $ SM.getFullVects tcmVect

        buildDC :: Vector BV.BV -> DynamicCharacter
        buildDC = encodeStream arbitraryAlphabet . fmap (NE.fromList . f 0 . BV.toBits) . NE.fromList  . toList

        f :: Word -> [Bool] -> [String]
        f _ [] = []
        f n (x:xs)
          | x = show n : f (n+1) xs
          | otherwise  = f (n+1) xs

        g :: Word -> [String] -> [Bool]
        g n [] = False : g (n+1) []
        g n (x:xs)
          | fromEnum n >= TCM.size tcm = []
          | read x == n = True  : g (n+1)    xs
          | otherwise   = False : g (n+1) (x:xs)


        arbitraryAlphabet :: Alphabet String
        arbitraryAlphabet = fromSymbols $ show <$> 0 :| [1 .. TCM.size tcm - 1]
