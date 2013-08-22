
module Data.Array.Repa.Plugin.Primitives
        ( Primitives (..)
        , slurpPrimitives)
where
import Data.Array.Repa.Plugin.Primitives.Selectors
import DDC.Core.Flow.Prim
import Data.List
import Data.Maybe
import Control.Monad

import qualified HscTypes       as G
import qualified CoreSyn        as G
import qualified DataCon        as G
import qualified TyCon          as G
import qualified Type           as G
import qualified MkId           as G
import qualified PrimOp         as G
import qualified Var            as G
import qualified OccName        as Occ
import qualified Name           as Name

import UniqSupply               as G
import qualified UniqSet        as US
import qualified Data.Map       as Map
import Data.Map                 (Map)


-------------------------------------------------------------------------------
-- | Table of GHC core expressions to use to invoke the primitives
--   needed by the lowering transform.
data Primitives
        = Primitives
        { prim_Series           :: !G.Type
        , prim_Vector           :: !G.Type
        , prim_Ref              :: !G.Type

          -- Loop combinators.
        , prim_natOfRateNat     :: (G.CoreExpr, G.Type)
        , prim_rateOfSeries     :: (G.CoreExpr, G.Type)
        , prim_loop             :: (G.CoreExpr, G.Type)
        , prim_guard            :: (G.CoreExpr, G.Type)

          -- Hacks
        , prim_nextInt_T2       :: (G.CoreExpr, G.Type)

          -- Primitives per base type.
        , prim_baseInt          :: Map Name (G.CoreExpr, G.Type)
        , prim_baseWord         :: Map Name (G.CoreExpr, G.Type)
        , prim_baseFloat        :: Map Name (G.CoreExpr, G.Type)
        , prim_baseDouble       :: Map Name (G.CoreExpr, G.Type)
        }


-------------------------------------------------------------------------------
-- | Try to slurp the primitive table from a GHC module.
--
--   The table should be in a top-level binding named "repa_primitives".
--   If we find it, then we add more top-level functions to the module 
--   that select the individual primitives, then build a table of expressions
--   that can be used to access them.
--
slurpPrimitives 
        :: G.ModGuts 
        -> UniqSM (Maybe (Primitives, G.ModGuts))

slurpPrimitives guts
 | Just vTable  <- listToMaybe 
                $  mapMaybe findTableFromTopBind 
                $  G.mg_binds guts
 = do   
        Just (prims, bsMoar) <- makeTable vTable

        let hackedGuts          
                = guts  
                { G.mg_binds    
                        = insertAfterTable bsMoar 
                        $ G.mg_binds guts
                
                , G.mg_used_names       
                        = US.addListToUniqSet (G.mg_used_names guts)
                        $ [G.varName b | G.NonRec b _ <- bsMoar ]}

        return  $ Just (prims, hackedGuts)

 | otherwise
 =      return Nothing
        

-------------------------------------------------------------------------------
-- | Try to find the primitive table in this top level binding.
findTableFromTopBind :: G.CoreBind -> Maybe G.Var
findTableFromTopBind bnd
 = case bnd of
        G.Rec{}         -> Nothing
        G.NonRec b _    -> findTableFromBinding b


-- | Try to find the primitive table in this top level binding.
--   It needs to be named "repa_primitives"
findTableFromBinding :: G.CoreBndr -> Maybe G.Var
findTableFromBinding b
        | strName      <- Occ.occNameString 
                       $  Name.nameOccName 
                       $  G.varName b
        , strName == "repa_primitives"
        = Just b

        | otherwise
        = Nothing


-------------------------------------------------------------------------------
-- | Insert some top-level bindings after the primitive table.
insertAfterTable :: [G.CoreBind] -> [G.CoreBind] -> [G.CoreBind]
insertAfterTable bsMore bs
 = case bs of
        []                      
         -> bs
        
        bb@G.Rec{} : bs'         
         -> bb : insertAfterTable bsMore bs'
        
        bb@(G.NonRec b _) : bs'
         |  isJust $ findTableFromBinding b
         -> bb : bsMore ++ bs'

         | otherwise
         -> bb : insertAfterTable bsMore bs'


-------------------------------------------------------------------------------
-- | Create top-level projection functions based on the primitive table
--   attached to this variable.
makeTable 
        :: G.Var 
        -> UniqSM (Maybe (Primitives, [G.CoreBind]))

makeTable v
 | t                      <- G.varType v
 , Just tc                <- G.tyConAppTyCon_maybe t
 , G.isAlgTyCon tc
 , G.DataTyCon [dc] False <- G.algTyConRhs tc
 = do
        let labels
                = G.dataConFieldLabels dc

        -- Load types from their proxy fields.
        let Just tySeries   
                = liftM (G.dataConFieldType dc)
                $ find (\n -> stringOfName n ==  "prim_Series") labels

        let Just tyVector   
                = liftM (G.dataConFieldType dc)
                $ find (\n -> stringOfName n ==  "prim_Vector") labels

        let Just tyRef
                = liftM (G.dataConFieldType dc)
                $ find (\n -> stringOfName n ==  "prim_Ref") labels

        -- Build table of selectors for all the external operators.
        -- Each selector projects the appropriate field from the primitives table.
        (bs, selectors)     <- makeSelectors v allExternalNames
        let get name
                = let Just r    = lookup name selectors
                  in  r

        -- Find the definition for some Core Flow primitive.
        --  It might be baked into GHC or externally implemented in the
        --  repa-primitives table.
        let populate 
                :: [(Name, G.Id)]       -- Direcrtly implemented operators.
                -> [(Name, String)]     -- Operators from the repa-primitives table.
                -> Name
                -> (Name, (G.CoreExpr, G.Type))

            populate bakedin prims name
             | Just gid <- lookup name bakedin 
             = (name, (G.Var gid, G.varType gid))

             | otherwise
             = let Just str = lookup name prims 
                   Just r   = lookup str selectors
               in  (name, r)

        let table      
                = Primitives
                { prim_Series           = tySeries
                , prim_Vector           = tyVector
                , prim_Ref              = tyRef

                -- Loop
                , prim_natOfRateNat     = get "prim_natOfRateNat"
                , prim_rateOfSeries     = get "prim_rateOfSeries" 
                , prim_loop             = get "prim_loop"
                , prim_guard            = get "prim_guard"

                -- Hacks
                , prim_nextInt_T2       = get "prim_nextInt_T2"

                -- Primitives per base type
                , prim_baseInt          = Map.fromList
                                        $ map (populate bakedin_int external_baseInt) 
                                        $  map fst external_baseInt
                                        ++ map fst bakedin_int

                , prim_baseWord         = Map.fromList
                                        $ map (populate bakedin_word external_baseWord) 
                                        $  map fst external_baseWord
                                        ++ map fst bakedin_word

                , prim_baseFloat        = Map.fromList
                                        $ map (populate bakedin_float external_baseFloat) 
                                        $   map fst external_baseFloat
                                        ++  map fst bakedin_float

                , prim_baseDouble       = Map.fromList
                                        $ map (populate bakedin_double external_baseDouble) 
                                        $  map fst external_baseDouble
                                        ++ map fst bakedin_double
                 }


        return $ Just (table, bs)

 | otherwise
 = return Nothing


-------------------------------------------------------------------------------
-- Baked in primitives are the ones that GHC implements directly.
--   Each of these tables map the DDC name for the primop at the appropriate
--   type onto the GHC Id for it.
--
bakedin_int :: [(Name, G.Id)]
bakedin_int 
 =      [ (NamePrimArith PrimArithAdd,  G.mkPrimOpId G.IntAddOp) 
        , (NamePrimArith PrimArithSub,  G.mkPrimOpId G.IntSubOp) 
        , (NamePrimArith PrimArithMul,  G.mkPrimOpId G.IntMulOp) 
        , (NamePrimArith PrimArithDiv,  G.mkPrimOpId G.IntQuotOp) 
        , (NamePrimArith PrimArithRem,  G.mkPrimOpId G.IntRemOp) 

        , (NamePrimArith PrimArithEq,   G.mkPrimOpId G.IntEqOp) 
        , (NamePrimArith PrimArithNeq,  G.mkPrimOpId G.IntNeOp) 
        , (NamePrimArith PrimArithGt,   G.mkPrimOpId G.IntGtOp) 
        , (NamePrimArith PrimArithGe,   G.mkPrimOpId G.IntGeOp) 
        , (NamePrimArith PrimArithLt,   G.mkPrimOpId G.IntLtOp) 
        , (NamePrimArith PrimArithLe,   G.mkPrimOpId G.IntLeOp) ]


bakedin_word :: [(Name, G.Id)]
bakedin_word 
 =      [ (NamePrimArith PrimArithAdd,  G.mkPrimOpId G.WordAddOp) 
        , (NamePrimArith PrimArithSub,  G.mkPrimOpId G.WordSubOp) 
        , (NamePrimArith PrimArithMul,  G.mkPrimOpId G.WordMulOp) 
        , (NamePrimArith PrimArithDiv,  G.mkPrimOpId G.WordQuotOp) 
        , (NamePrimArith PrimArithRem,  G.mkPrimOpId G.WordRemOp) 

        , (NamePrimArith PrimArithEq,   G.mkPrimOpId G.WordEqOp) 
        , (NamePrimArith PrimArithNeq,  G.mkPrimOpId G.WordNeOp) 
        , (NamePrimArith PrimArithGt,   G.mkPrimOpId G.WordGtOp) 
        , (NamePrimArith PrimArithGe,   G.mkPrimOpId G.WordGeOp) 
        , (NamePrimArith PrimArithLt,   G.mkPrimOpId G.WordLtOp) 
        , (NamePrimArith PrimArithLe,   G.mkPrimOpId G.WordLeOp) ]


bakedin_float :: [(Name, G.Id)]
bakedin_float
 =      [ (NamePrimArith PrimArithAdd,  G.mkPrimOpId G.FloatAddOp) 
        , (NamePrimArith PrimArithSub,  G.mkPrimOpId G.FloatSubOp) 
        , (NamePrimArith PrimArithMul,  G.mkPrimOpId G.FloatMulOp) 
        , (NamePrimArith PrimArithDiv,  G.mkPrimOpId G.FloatDivOp) 

        , (NamePrimArith PrimArithEq,   G.mkPrimOpId G.FloatEqOp) 
        , (NamePrimArith PrimArithNeq,  G.mkPrimOpId G.FloatNeOp) 
        , (NamePrimArith PrimArithGt,   G.mkPrimOpId G.FloatGtOp) 
        , (NamePrimArith PrimArithGe,   G.mkPrimOpId G.FloatGeOp) 
        , (NamePrimArith PrimArithLt,   G.mkPrimOpId G.FloatLtOp) 
        , (NamePrimArith PrimArithLe,   G.mkPrimOpId G.FloatLeOp) ]


bakedin_double :: [(Name, G.Id)]
bakedin_double 
 =      [ (NamePrimArith PrimArithAdd,  G.mkPrimOpId G.DoubleAddOp) 
        , (NamePrimArith PrimArithSub,  G.mkPrimOpId G.DoubleSubOp) 
        , (NamePrimArith PrimArithMul,  G.mkPrimOpId G.DoubleMulOp) 
        , (NamePrimArith PrimArithDiv,  G.mkPrimOpId G.DoubleDivOp) 

        , (NamePrimArith PrimArithEq,   G.mkPrimOpId G.DoubleEqOp) 
        , (NamePrimArith PrimArithNeq,  G.mkPrimOpId G.DoubleNeOp) 
        , (NamePrimArith PrimArithGt,   G.mkPrimOpId G.DoubleGtOp) 
        , (NamePrimArith PrimArithGe,   G.mkPrimOpId G.DoubleGeOp) 
        , (NamePrimArith PrimArithLt,   G.mkPrimOpId G.DoubleLtOp) 
        , (NamePrimArith PrimArithLe,   G.mkPrimOpId G.DoubleLeOp) ]


-------------------------------------------------------------------------------
-- External primitives are the ones implemented in the repa-series package.
--   We get their names from the primitives table exported by repa-series,
--   and build a selector function to project out the element of the table.
--

-- | Names of all external operators imported from the repa-series package.
allExternalNames :: [String]
allExternalNames
 =      (map snd external_control)
 ++     (map snd external_series)
 ++     [ "prim_nextInt_T2" ]           -- HACKS: Needs to die.
 ++     (map snd external_baseInt)
 ++     (map snd external_baseWord)
 ++     (map snd external_baseFloat)
 ++     (map snd external_baseDouble)


-- | Names of loop combinators.
external_control :: [(Name, String)]
external_control
 =      [ (NameOpControl OpControlLoop,         "prim_loop")
        , (NameOpControl OpControlGuard,        "prim_guard") ]


-- | Name of series primitives.
external_series :: [(Name, String)]
external_series 
 =      [ (NameOpSeries OpSeriesRateOfSeries,   "prim_rateOfSeries") 
        , (NameOpSeries OpSeriesNatOfRateNat,   "prim_natOfRateNat") ]


-- | Map Core Flow Name to the base name used in the imported primitive table.
--   To turn this into the external name we need to add  a "prim_" prefix and
--   TYPE suffix.  Like "add" => "prim_addInt"
external_baseTYPE :: [(Name, String)]
external_baseTYPE
 =      [ (NameOpSeries  (OpSeriesNext 1),      "next") 

        , (NameOpStore OpStoreNew,              "newRef")
        , (NameOpStore OpStoreRead,             "readRef")
        , (NameOpStore OpStoreWrite,            "writeRef")

        , (NameOpStore OpStoreNewVectorN,       "newVector")
        , (NameOpStore (OpStoreReadVector  1),  "readVector")
        , (NameOpStore (OpStoreWriteVector 1),  "writeVector")
        , (NameOpStore OpStoreSliceVector,      "sliceVector") ]


-- | Primitive table names for Int operators.
external_baseInt    :: [(Name, String)]
external_baseInt
 =      [ (n, "prim_" ++ s ++ "Int")    | (n, s) <- external_baseTYPE ]


-- | Primitive table names for Word operators.
external_baseWord   :: [(Name, String)]
external_baseWord
 =      [ (n, "prim_" ++ s ++ "Word")   | (n, s) <- external_baseTYPE ]


-- | Primitive table names for Float operators.
external_baseFloat  :: [(Name, String)]
external_baseFloat
 =      [ (n, "prim_" ++ s ++ "Float")  | (n, s) <- external_baseTYPE ]


-- | Primitive table names for Double operators.
external_baseDouble :: [(Name, String)]
external_baseDouble
 =      [ (n, "prim_" ++ s ++ "Double") | (n, s) <- external_baseTYPE ]

