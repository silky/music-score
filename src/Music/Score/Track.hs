
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE UndecidableInstances       #-}

-------------------------------------------------------------------------------------
-- |
-- Copyright   : (c) Hans Hoglund 2012
--
-- License     : BSD-style
--
-- Maintainer  : hans@hanshoglund.se
-- Stability   : experimental
-- Portability : non-portable (TF,GNTD)
--
-- Provides the 'Track' type.
--
-------------------------------------------------------------------------------------

module Music.Score.Track (
        -- * Track type
        Track,
        track',
        track,
        -- mkTrack,
        -- getTrack,
  ) where

import           Control.Applicative
import           Control.Arrow
import           Control.Lens
import           Control.Monad
import           Control.Monad.Compose
import           Data.AffineSpace.Point
import           Data.Foldable          (Foldable (..), foldMap)
import qualified Data.Foldable          as F
import qualified Data.List              as List
import           Data.PairMonad         ()
import           Data.Semigroup
import           Data.Traversable       (Traversable (..))
import qualified Data.Traversable       as T
import           Data.Typeable
import           Data.VectorSpace       hiding (Sum)
-- import           Test.QuickCheck        (Arbitrary (..), Gen (..))

import           Music.Dynamics.Literal
import           Music.Pitch.Literal
import           Music.Score.Pitch
import           Music.Score.Util
import           Music.Time

-- |
-- A track is a list of events with explicit onset.
--
-- Track is a 'Monoid' under parallel composition. 'mempty' is the empty track
-- and 'mappend' interleaves values.
--
-- Track is a 'Monad'. 'return' creates a track containing a single value at time
-- zero, and '>>=' transforms the values of a track, allowing the addition and
-- removal of values relative to the time of the value. Perhaps more intuitively,
-- 'join' delays each inner track to start at the offset of an outer track, then
-- removes the intermediate structure.
--
-- > let t = Track [(0, 65),(1, 66)]
-- >
-- > t >>= \x -> Track [(0, 'a'), (10, toEnum x)]
-- >
-- >   ==> Track {getTrack = [ (0.0,  'a'),
-- >                           (1.0,  'a'),
-- >                           (10.0, 'A'),
-- >                           (11.0, 'B') ]}
--
-- Track is an instance of 'VectorSpace' using parallel composition as addition,
-- and time scaling as scalar multiplication.
--
newtype Track a = Track { getTrack' :: [Occ a] }
    deriving (Eq, Ord, Show, Functor, Foldable, Typeable, Traversable, Monoid, Semigroup, Delayable, Stretchable)

{-
instance Semigroup (Track a) where
    (<>) = mappend

-- Equivalent to the derived Monoid, except for the sorted invariant.
instance Monoid (Track a) where
    mempty = Track []
    Track as `mappend` Track bs = Track (as `m` bs)
        where
            m = mergeBy (comparing fst)
-}

instance Wrapped (Track a) where
    type Unwrapped (Track a) = [Occ a]
    _Wrapped' = iso getTrack' Track

instance Applicative Track where
    pure  = return
    (<*>) = ap

instance Monad Track where
    return = (^. _Unwrapped') . return . return
    xs >>= f = (^. _Unwrapped') $ mbind ((^. _Wrapped') . f) ((^. _Wrapped') xs)

instance Alternative Track where
    empty = mempty
    (<|>) = mappend

instance MonadPlus Track where
    mzero = mempty
    mplus = mappend

instance HasOnset (Track a) where
    onset (Track a) = list origin (onset . head) a

instance IsPitch a => IsPitch (Track a) where
    fromPitch = pure . fromPitch

instance IsDynamics a => IsDynamics (Track a) where
    fromDynamics = pure . fromDynamics

instance IsInterval a => IsInterval (Track a) where
    fromInterval = pure . fromInterval

type instance Pitch (Track a) = Pitch a
instance (HasSetPitch a b, Transformable (Pitch (Track a)), Transformable (Pitch (Track b))) => HasSetPitch (Track a) (Track b) where
    type SetPitch g (Track a) = Track (SetPitch g a)
    -- FIXME this is wrong, need to behave like __mapPitch'
    __mapPitch f   = fmap (__mapPitch f)


-- |
-- Create a voice from a list of occurences.
--
track' :: Iso' [(Time, a)] (Track a)
track' = track

-- |
-- Create a voice from a list of occurences.
--
track :: Iso [(Time, a)] [(Time, b)] (Track a) (Track b)
track = iso mkTrack getTrack
    where
        mkTrack = Track . fmap (uncurry occ . first (fmap realToFrac))
        getTrack = fmap (first (fmap realToFrac) . getOcc) . getTrack'



newtype Occ a = Occ (Sum Time, a)
    deriving (Eq, Ord, Show, {-Read, -}Functor, Applicative, Monad, Foldable, Traversable)

occ t x = Occ (Sum t, x)
getOcc (Occ (Sum t, x)) = (t, x)

instance Delayable (Occ a) where
    delay n (Occ (s,x)) = Occ (delay n s, x)
instance Stretchable (Occ a) where
    stretch n (Occ (s,x)) = Occ (stretch n s, x)
instance HasOnset (Occ a) where
    onset (Occ (s,x)) = onset s

