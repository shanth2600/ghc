module TyCon where

import GhcPrelude

data TyCon
data PrimConv

isTupleTyCon        :: TyCon -> Bool
isUnboxedTupleTyCon :: TyCon -> Bool
isFunTyCon          :: TyCon -> Bool
isFunTildeTyCon     :: TyCon -> Bool