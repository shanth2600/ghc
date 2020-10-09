module TysWiredIn where

import Var( TyVar, ArgFlag )
import {-# SOURCE #-} TyCon      ( TyCon, PrimConv )
import {-# SOURCE #-} TyCoRep    (Type, Kind)


mkFunKind :: Kind -> Kind -> Kind
mkForAllKind :: TyVar -> ArgFlag -> Kind -> Kind

listTyCon :: TyCon
intTy, typeNatKind, typeSymbolKind :: Type
mkBoxedTupleTy :: [Type] -> Type

coercibleTyCon, heqTyCon :: TyCon

liftedTypeKind :: Kind
constraintKind :: Kind

runtimeRepTyCon, vecCountTyCon, vecElemTyCon :: TyCon
runtimeRepTy :: Type


ptrRepDataConTyCon, vecRepDataConTyCon, tupleRepDataConTyCon,
  convCountDataConTyCon, convLevityDataConTyCon, convLevityTyDataConTyCon :: TyCon

ptrRepDataConTy, intRepDataConTy, wordRepDataConTy, int64RepDataConTy, 
  word64RepDataConTy, addrRepDataConTy, floatRepDataConTy, doubleRepDataConTy, 
  convLevityTy, runtimeConvTy, convLevityLiftedTy, convLevityUnliftedTy :: Type

vec2DataConTy, vec4DataConTy, vec8DataConTy, vec16DataConTy, vec32DataConTy,
  vec64DataConTy :: Type

int8ElemRepDataConTy, int16ElemRepDataConTy, int32ElemRepDataConTy,
  int64ElemRepDataConTy, word8ElemRepDataConTy, word16ElemRepDataConTy,
  word32ElemRepDataConTy, word64ElemRepDataConTy, floatElemRepDataConTy,
  doubleElemRepDataConTy :: Type

anyTypeOfKind :: Kind -> Type
unboxedTupleKind :: [Type] -> Type
mkPromotedListTy :: Type -> [Type] -> Type
