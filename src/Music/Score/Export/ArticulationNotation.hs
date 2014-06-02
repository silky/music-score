
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE DeriveFoldable             #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE DeriveTraversable          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}

-------------------------------------------------------------------------------------
-- |
-- Copyright   : (c) Hans Hoglund 2012-2014
--
-- License     : BSD-style
--
-- Maintainer  : hans@hanshoglund.se
-- Stability   : experimental
-- Portability : non-portable (TF,GNTD)
--
-------------------------------------------------------------------------------------

module Music.Score.Export.ArticulationNotation (
    Slur(..),
    Mark(..),
    ArticulationNotation(..),
    notateArticulation,
  ) where

import Data.Semigroup
import Data.Functor.Context
import Control.Lens -- ()
import Music.Score.Articulation
import Music.Score.Ties
import Music.Time

-- TODO need NoSlur etc?

data Slur = NoSlur | BeginSlur | EndSlur
  deriving (Eq, Ord, Show)

-- data CrescDim = NoCrescDim | BeginCresc | EndCresc | BeginDim | EndDim
data Mark = NoMark | Staccato | MoltoStaccato | Marcato | Accent | Tenuto
  deriving (Eq, Ord, Show)

instance Monoid Slur where
  mempty = NoSlur
  mappend NoSlur a = a
  mappend a NoSlur = a
  mappend a _ = a

instance Monoid Mark where
  mempty = NoMark
  mappend NoMark a = a
  mappend a NoMark = a
  mappend a _ = a

newtype ArticulationNotation 
  = ArticulationNotation { getArticulationNotation :: ([Slur], [Mark]) }

instance Wrapped ArticulationNotation where
  type Unwrapped ArticulationNotation = ([Slur], [Mark])
  _Wrapped' = iso getArticulationNotation ArticulationNotation

instance Rewrapped ArticulationNotation ArticulationNotation

type instance Articulation ArticulationNotation = ArticulationNotation

instance Transformable ArticulationNotation where
  transform _ = id

instance Tiable ArticulationNotation where
  toTied (ArticulationNotation (beginEnd, marks)) 
    = (ArticulationNotation (beginEnd, marks), 
       ArticulationNotation (mempty, mempty))

instance Monoid ArticulationNotation where
  mempty = ArticulationNotation ([], [])
  ArticulationNotation ([], []) `mappend` y = y
  x `mappend` ArticulationNotation ([], []) = x
  x `mappend` y = x

notateArticulation :: (Ord a, a ~ (Product Double, Product Double)) => Ctxt a -> ArticulationNotation
notateArticulation x = mempty
  -- = ArticulationNotation $ over _2 (\t -> if t then Just (realToFrac $ extractCtxt x) else Nothing) $ case x of
  -- (Nothing, y, Nothing) -> ([], True)
  -- (Nothing, y, Just z ) -> case (y `compare` z) of
  --   LT      -> ([BeginCresc], True)
  --   EQ      -> ([],           True)
  --   GT      -> ([BeginDim],   True)
  -- (Just x,  y, Just z ) -> case (x `compare` y, y `compare` z) of
  --   (LT,LT) -> ([NoCrescDim], False)
  --   (LT,EQ) -> ([EndCresc],   True)
  --   (EQ,LT) -> ([BeginCresc], False{-True-})
  -- 
  --   (GT,GT) -> ([NoCrescDim], False)
  --   (GT,EQ) -> ([EndDim],     True)
  --   (EQ,GT) -> ([BeginDim],   False{-True-})
  -- 
  --   (EQ,EQ) -> ([],                   False)
  --   (LT,GT) -> ([EndCresc, BeginDim], True)
  --   (GT,LT) -> ([EndDim, BeginCresc], True)
  -- 
  -- 
  -- (Just x,  y, Nothing) -> case (x `compare` y) of
  --   LT      -> ([EndCresc],   True)
  --   EQ      -> ([],           False)
  --   GT      -> ([EndDim],     True)
  --                                     
