------------------------------------------------------------------------------
-- |
-- Module      :  Numeric.NonNegativeAverage.Test
-- Copyright   :  (c) 2015-2021 Ward Wheeler
-- License     :  BSD-style
--
-- Maintainer  :  wheeler@amnh.org
-- Stability   :  provisional
-- Portability :  portable
--
-----------------------------------------------------------------------------

{-# LANGUAGE FlexibleInstances #-}

module Numeric.NonNegativeAverage.Test
  ( testSuite
  ) where


import Data.Ratio
import Numeric.NonNegativeAverage
import Test.Tasty
import Test.Tasty.QuickCheck


-- |
-- Test-suite with property-based tests for the 'NonNegativeAverage' data-type.
testSuite :: TestTree
testSuite = testGroup "NonNegativeAverage tests"
    [ testInvariantProperties
    ]


testInvariantProperties :: TestTree
testInvariantProperties = testGroup "Invariant properties"
    [ orderingProperties
    , semigroupProperties
    ]


orderingProperties :: TestTree
orderingProperties = testGroup "Properties of ordering"
    [ testProperty "ordering preserves symmetry"  symmetry
    , testProperty "order preserving projection" orderPreserving
    ]
  where
    orderPreserving :: (Word, Word) -> Bool
    orderPreserving (a, b) = a `compare` b == fromNonNegativeValue a `compare` fromNonNegativeValue b

    symmetry :: (NonNegativeAverage, NonNegativeAverage) -> Bool
    symmetry (a, b) =
      case (a `compare` b, b `compare` a) of
        (EQ, EQ) -> True
        (GT, LT) -> True
        (LT, GT) -> True
        _        -> False


semigroupProperties :: TestTree
semigroupProperties = testGroup "Properties of this semigroup operator"
    [ testProperty "projection identity holds" projectionIdentity
    , localOption (QuickCheckTests 10000)
        $ testProperty "(<>) is associative" operationAssocativity
    , localOption (QuickCheckTests  1000)
        $ testProperty "(<>) is commutative" operationCommutativity
    ]
  where
    projectionIdentity :: Word -> Bool
    projectionIdentity x = let (n,d) = f x in n == x && d == 1
      where
        f :: Word -> (Word, Word)
        f = ((,) <$> fromInteger . numerator <*> fromInteger . denominator) . g

        g :: Word -> Rational
        g = fromNonNegativeAverage . fromNonNegativeValue

    operationAssocativity :: (NonNegativeAverage, NonNegativeAverage, NonNegativeAverage) -> Bool
    operationAssocativity (a, b, c) = a <> (b <> c) == (a <> b) <> c

    operationCommutativity :: (NonNegativeAverage, NonNegativeAverage) -> Bool
    operationCommutativity (a, b) = a <> b == b <> a
