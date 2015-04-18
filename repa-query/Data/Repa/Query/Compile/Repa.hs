{-# LANGUAGE TemplateHaskell, QuasiQuotes #-}

-- | Compilation of Repa queries to native code by 
--   emitting a Haskell program using repa-flow and compiling it with GHC.
module Data.Repa.Query.Compile.Repa
        ( decOfQuery
        , expOfQuery)
where
import Language.Haskell.TH              as H
import Data.Repa.Flow                   as F
import Data.Repa.Flow.Auto.IO           as F
import Data.Repa.Flow.Auto.Format       as F
import Data.Repa.Query.Graph            as G
import Data.Repa.Query.Format           as Q
import Data.Repa.Convert.Format         as C


---------------------------------------------------------------------------------------------------
-- | Yield a top-level Haskell declararation for a query.
--
--   The query expression is bound to the given name.
decOfQuery   
        :: Name
        -> G.Query () String String String 
        -> Q H.Dec

decOfQuery nResult query
 = do   hexp    <- expOfQuery query
        return  $ H.ValD (H.VarP nResult) (H.NormalB hexp) []


---------------------------------------------------------------------------------------------------
-- | Yield a Haskell expression for a query
expOfQuery   :: G.Query  () String String String -> Q H.Exp
expOfQuery (G.Query sResult format (G.Graph nodes))
 = case format of
        Fixed{}
         -> [| $sources >>= F.concatPackFormat_i  $format' |]

        Lines{}
         -> [| $sources >>= F.unlinesPackFormat_i $format' |]

        LinesSep{}
         -> [| $sources >>= F.unlinesPackFormat_i $format' |]

 where  sources 
         = go nodes

        Just format'
         = expOfRowFormat format

        go []   
         = do   let hResult     = H.varE (H.mkName sResult)
                [| return $hResult |]

        go (n : ns)
         = do   (hPat, hRhs)    <- bindOfNode n
                [| $(return hRhs) >>= \ $(return hPat) -> $(go ns) |]


---------------------------------------------------------------------------------------------------
-- | Yield a Haskell binding for a flow node.
bindOfNode   :: G.Node   () String String String -> Q (H.Pat, H.Exp)
bindOfNode nn
 = case nn of
        G.NodeSource source     -> bindOfSource source
        G.NodeOp     op         -> bindOfFlowOp op


-- | Yield a Haskell binding for a flow op.
bindOfSource :: G.Source () String -> Q (H.Pat, H.Exp)
bindOfSource ss
 = case ss of
        G.SourceTable _ tableName format@Lines{} sOut
         -> do  let hTable       = return (LitE (StringL tableName))
                let Just format' = expOfRowFormat format

                xRhs    <- [| fromFiles [ $hTable ] 
                                (F.sourceLinesFormat 
                                        (64 * 1024)
                                        (error "line to long")
                                        (error "cannot convert")
                                        $format') |]

                pOut    <- H.varP (H.mkName sOut)
                return (pOut, xRhs)


        G.SourceTable _ tableName format@LinesSep{} sOut
         -> do  let hTable       = return (LitE (StringL tableName))
                let Just format' = expOfRowFormat format

                xRhs    <- [| fromFiles [ $hTable ] 
                                (F.sourceLinesFormat 
                                        (64 * 1024)
                                        (error "line to long")
                                        (error "cannot convert")
                                        $format') |]

                pOut    <- H.varP (H.mkName sOut)
                return (pOut, xRhs)


        G.SourceTable _ tableName format@Fixed{} sOut
         -> do  let hTable       = return (LitE (StringL tableName))
                let Just format' = expOfRowFormat format

                xRhs    <- [| fromFiles [ $hTable ]
                                (F.sourceFixedFormat
                                        $format'
                                        (error "cannot convert")) |]

                pOut    <- H.varP (H.mkName sOut)
                return (pOut, xRhs)


-- | Yield a Haskell binding for a flow op.
bindOfFlowOp :: G.FlowOp () String String String -> Q (H.Pat, H.Exp)
bindOfFlowOp op
 = case op of
        G.FopMapI sIn sOut xFun
         -> do  let hIn         =  H.varE (H.mkName sIn)
                pOut            <- H.varP (H.mkName sOut)
                hRhs            <- [| F.map_i $(expOfExp xFun) $hIn |]
                return  (pOut, hRhs)

{-      TODO: add filter to repa-flow API
        G.FopFilterI sIn sOut xFun
         -> do  let hIn         = H.varE (H.mkName sIn)
                pOut            <- H.varP (H.mkName sOut)
                let hFun        = expOfExp xFun
                hRhs            <- [| F.filter_i $hFun $hIn |]
                return  (pOut, hRhs)


        TODO: add fold to single elem to repa-flow API
        G.FopFoldI  sIn sOut xFun xNeu
         -> do  let hInElems    =  H.varE (H.mkName sIn)
                pOut            <- H.varP (H.mkName sOut)
                let hFun        = expOfExp xFun
                let hNeu        = expOfExp xNeu
                hRhs            <- [| F.folds_i $hFun $hNeu $hInLens $hInElems |]
                return  (pOut, hRhs)
-}

        G.FopFoldsI sInLens sInElems sOut xFun xNeu
         -> do  let hInLens     =  H.varE (H.mkName sInLens)
                let hInElems    =  H.varE (H.mkName sInElems)
                pOut            <- H.varP (H.mkName sOut)
                hRhs            <- [| F.folds_i $(expOfExp xFun) $(expOfExp xNeu) 
                                                $hInLens         $hInElems |]
                return  (pOut, hRhs)


        G.FopGroupsI sIn sOut xFun
         -> do  let hIn         =  H.varE (H.mkName sIn)
                pOut            <- H.varP (H.mkName sOut)
                hRhs            <- [|     F.map_i (\(g, n) -> g :*: n)
                                      =<< F.groupsBy_i $(expOfExp xFun) $hIn |]
                                      
                return  (pOut, hRhs)

        _ -> error "finish bindOfFlowOp"


---------------------------------------------------------------------------------------------------
-- | Yield a Haskell expression from a query scalar expression.
expOfExp   :: G.Exp () String String -> H.ExpQ 
expOfExp xx
 = case xx of
        G.XVal _ (G.VLit _ lit)
         -> do  hl      <- litOfLit lit
                H.litE hl

        G.XVal _ (G.VLam _ sBind xBody)
         -> H.lamE [H.varP (H.mkName sBind)] (expOfExp xBody)

        G.XVar _ str
         -> H.varE (H.mkName str)

        G.XApp _ x1 x2
         -> H.appsE [expOfExp x1, expOfExp x2]

        G.XOp  _ sop xsArgs
         -> H.appsE (expOfScalarOp sop : map expOfExp xsArgs)


-- | Yield a Haskell expression from a query scalar op.
expOfScalarOp :: ScalarOp -> H.ExpQ
expOfScalarOp sop
 = case sop of
        SopNeg  -> [| negate |]
        SopAdd  -> [| (+)  |]
        SopSub  -> [| (-)  |]
        SopMul  -> [| (*)  |]
        SopDiv  -> [| (/)  |]
        SopEq   -> [| (==) |]
        SopNeq  -> [| (<=) |]
        SopGt   -> [| (>)  |]
        SopGe   -> [| (>=) |]
        SopLt   -> [| (<)  |]
        SopLe   -> [| (<=) |]


-- | Yield a Haskell literal from a query literal.
litOfLit :: G.Lit -> Q H.Lit
litOfLit lit 
 = case lit of
        G.LInt i        -> return $ H.IntegerL i
        G.LString s     -> return $ H.StringL  s
        _               -> error "fix float conversion"


---------------------------------------------------------------------------------------------------
-- | Yield a Haskell expression for a row format.
expOfRowFormat :: Q.Row -> Maybe H.ExpQ
expOfRowFormat row
 = case row of
        Q.Fixed     [f]
         -> Just [| $(expOfFieldFormat f) |]

        Q.Fixed     (f:fs)
         -> Just [| C.App $(expOfFieldFormats f fs) |]

        Q.Lines f
         -> Just [| $(expOfFieldFormat f) |]

        Q.LinesSep _c [f]
         -> Just [| $(expOfFieldFormat f) |]

        Q.LinesSep c (f:fs) 
         -> Just [| C.Sep $(H.litE (H.charL c)) $(expOfFieldFormats f fs) |]

        _ -> Nothing


-- | Yield a Haskell expression for some fields.
expOfFieldFormats :: Q.Field -> [Q.Field] -> H.ExpQ 
expOfFieldFormats f1 []        
        = expOfFieldFormat f1

expOfFieldFormats f1 (f2 : fs) 
        = [| $(expOfFieldFormat f1) C.:*: $(expOfFieldFormats f2 fs) |]


-- | Yield a Haskell expression for a field format.
expOfFieldFormat   :: Q.Field -> H.ExpQ
expOfFieldFormat format
 = case format of
        Q.Word8be       -> [| C.Word8be   |]
        Q.Int8be        -> [| C.Int8be    |]

        Q.Word16be      -> [| C.Word16be  |]
        Q.Int16be       -> [| C.Int16be   |]

        Q.Word32be      -> [| C.Word32be  |]
        Q.Int32be       -> [| C.Int32be   |] 

        Q.Word64be      -> [| C.Word64be  |]
        Q.Int64be       -> [| C.Int64be   |]

        Q.Float32be     -> [| C.Float32be |]
        Q.Float64be     -> [| C.Float64be |]

        Q.YYYYsMMsDD c  -> [| C.YYYYsMMsDD $(H.litE (H.charL c)) |]
        Q.DDsMMsYYYY c  -> [| C.DDsMMsYYYY $(H.litE (H.charL c)) |]

        Q.IntAsc        -> [| C.IntAsc    |]
        Q.DoubleAsc     -> [| C.DoubleAsc |]

        Q.FixAsc len    -> [| C.FixAsc $(H.litE (H.integerL (fromIntegral len))) |]
        Q.VarAsc        -> [| C.VarAsc    |]

