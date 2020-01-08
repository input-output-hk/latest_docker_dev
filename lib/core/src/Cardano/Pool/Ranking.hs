{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- | A self contained module for ranking pools according to the delegation design
-- spec /Design Specification for Delegation and Incentives in Cardano/
-- [(Kant et al, 2019)](https://hydra.iohk.io/build/1389333/download/1/delegation_design_spec.pdf).
--
-- The module currently implements the non-myopic desirability, and might later
-- support calculating the full non-myopic pool member rewards. The latter being
-- the recomended way to rank stake-pools (see section 4.3).
--
-- The term non-myopic is explained on page 37:
--
-- @
-- It would be short-sighted (“myopic”) for stakeholders to directly use the
-- reward splitting formulas from Section 6.5. They should instead take the
-- long-term (“non-myopic”) view. To this end, the system will calculate and
-- display the “non-myopic” rewards that pool leaders and pool members can
-- expect, thus supporting stakeholders in their decision whether to create a
-- pool and to which pool to delegate their stake.
--
-- The idea is to first rank all pools by “desirability”, to then assume that
-- the k most desirable pools will eventually be saturated, whereas all other
-- pools will lose all their members, then to finally base all reward
-- calculations on these assumptions.
-- @
--
-- == Relevant identifiers
--
-- Epoch Parameters
--
-- +------------+-------------+------------------------------------------------+
-- |identifier  | domain      | description                                    |
-- +============+=============+================================================+
-- + R          | @ [0, ∞) @  | total available rewards for the epoch (in ada).|
-- +------------+-------------+------------------------------------------------+
-- + a0         | @ [0, ∞) @  | owner-stake influence on pool rewards.         |
-- +------------+-------------+------------------------------------------------+
-- + k          | @ [0, ∞) @  | desired number of pools                        |
-- +------------+-------------+------------------------------------------------+
-- + z0         | 1/k         | relative stake of a saturated pool             |
-- +------------+-------------+------------------------------------------------+
--
-- Pool's Parameters
--
-- +------------+-------------+------------------------------------------------+
-- |identifier  | domain      | description                                    |
-- +============+=============+================================================+
-- | c          | @ [0, ∞)@   | costs                                          |
-- +------------+-------------+------------------------------------------------+
-- | f          | @ [0, ∞) @  | rewards                                        |
-- +------------+-------------+------------------------------------------------+
-- | m          | @ [0, 1] @  | margin                                         |
-- +------------+-------------+------------------------------------------------+
-- | p_apparent | @ [0, 1] @  | apparent performance                           |
-- +------------+-------------+------------------------------------------------+
-- | s          | @ [0, ∞) @  | relative stake of the pool leader (i.e pledge) |
-- +------------+-------------+------------------------------------------------+
-- | σ          | @ [0, 1] @  | total relative stake of the pool               |
-- +------------+-------------+------------------------------------------------+
module Cardano.Pool.Ranking
    (
      -- * Formulas
      desirability

    , saturatedPoolRewards
    , saturatedPoolSize

      -- * Types
    , EpochConstants (..)
    , Pool (..)
    , RelativeStakeOf (..)
    , mkRelativeStake
    , Lovelace (..)
    , Margin
    , unsafeMkMargin
    , getMargin
    , NonNegative (..)
    , Positive (..)
    , unsafeToPositive
    , unsafeToNonNegative
    )
    where

import Prelude

import GHC.Generics
    ( Generic )
import GHC.TypeLits
    ( Symbol )

--------------------------------------------------------------------------------
-- Formulas from spec
--------------------------------------------------------------------------------

-- | Non-myopic pool desirability according to section 5.6.1.
--
-- Is /not/ affected by oversaturation nor pool stake in general.
desirability
    :: EpochConstants
    -> Pool
    -> Double
desirability constants pool
    | f_saturated <= c = 0
    | otherwise    = (f_saturated - c) * (1 - m)
  where
    f_saturated = saturatedPoolRewards constants pool
    m = getMargin $ margin pool
    c = getNonNegative $ getLovelace $ cost pool

-- | Total rewards for a pool if it were saturated.
--
-- When a0 = 0 this reduces to just p*R*z0 (tested
-- by @prop_saturatedPoolRewardsReduces@)
saturatedPoolRewards :: EpochConstants -> Pool -> Double
saturatedPoolRewards constants pool =
    let
        a0 = getNonNegative $ leaderStakeInfluence constants
        z0 = unRelativeStake $ saturatedPoolSize constants
        s = unRelativeStake $ leaderStake pool
        _R = getNonNegative $ getLovelace $ totalRewards constants
        p = getNonNegative $ recentAvgPerformance pool
        -- ^ technically \hat{p} in the spec
    in
        (p * _R) / (1 + a0)
        * (z0 + ((min s z0) * a0))

-- | Determines z0, i.e 1 / k
saturatedPoolSize :: EpochConstants -> RelativeStakeOf "pool"
saturatedPoolSize constants =
    RelativeStake $ 1 / fromIntegral (getPositive $ optimalNumberOfPools constants)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

data EpochConstants = EpochConstants
    { leaderStakeInfluence :: NonNegative Double
      -- ^ a_0
    , optimalNumberOfPools :: Positive Int
      -- ^ k
    , totalRewards :: Lovelace
      -- ^ Total rewards in an epoch. "R" in the spec.
    } deriving (Show, Eq, Generic)

data Pool = Pool
    { leaderStake :: RelativeStakeOf "pool leader"
    , cost :: Lovelace
    , margin :: Margin
    , recentAvgPerformance :: NonNegative Double
      -- ^ An already averaged performance-value
    } deriving (Show, Eq, Generic)

newtype Lovelace = Lovelace { getLovelace :: NonNegative Double }
    deriving (Show, Eq)
    deriving newtype (Ord, Num)

newtype Margin = Margin { getMargin :: Double }
    deriving (Show, Eq)
    deriving newtype Ord

unsafeMkMargin :: Double -> Margin
unsafeMkMargin x
    | x >= 0 && x <= 1  = Margin x
    | otherwise         = error $ "unsafeMkMargin: " ++ show x
                          ++ "not in range [0, 1]"

-- | Stake relative to the total active stake in an epoch
--
-- The value
-- 0.01 :: RelativeStakeOf "pool"
-- would mean that a pool has a stake that is 1% of the total active stake in
-- the epoch.
newtype RelativeStakeOf (tag :: Symbol)
    = RelativeStake { unRelativeStake :: Double }
    deriving (Eq, Ord, Show, Generic)
    deriving newtype (Num, Fractional)

mkRelativeStake :: Lovelace -> EpochConstants -> RelativeStakeOf (tag :: Symbol)
mkRelativeStake (Lovelace (NonNegative stake)) constants =
    RelativeStake $ stake / total
  where
    total = getNonNegative $ getLovelace $ totalRewards constants

newtype Positive a = Positive { getPositive :: a }
    deriving (Generic, Eq, Show)
    deriving newtype (Ord, Num)

unsafeToPositive :: (Ord a, Show a, Num a) => a -> (Positive a)
unsafeToPositive x
    | x > 0    = Positive x
    | otherwise = error $ "unsafeToPositive: " ++ show x ++ " > 0 does not hold"

newtype NonNegative a = NonNegative { getNonNegative :: a }
    deriving (Generic, Eq, Show)
    deriving newtype (Ord, Num)

unsafeToNonNegative :: (Ord a, Show a, Num a) => a -> (NonNegative a)
unsafeToNonNegative x
    | x >= 0    = NonNegative x
    | otherwise = error $ "unsafeToNegative: " ++ show x ++ " >= 0 does not hold"
