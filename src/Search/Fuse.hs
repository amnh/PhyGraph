-- Used defaultParStrat for fusing operations--hopefully reduce memory footprint

{- |
Module specifying graph fusing recombination functions.
-}
module Search.Fuse (
    fuseAllGraphs,
) where

import Control.Monad (filterM, when)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Random.Class
import Data.BitVector.LittleEndian qualified as BV
import Data.Bits
import Data.Foldable (fold)
import Data.Functor ((<&>))
import Data.InfList qualified as IL
import Data.List qualified as L
import Data.Map qualified as MAP
import Data.Maybe
import Data.Text.Lazy qualified as TL
import Data.Vector qualified as V
import GeneralUtilities
import GraphOptimization.PostOrderSoftWiredFunctions qualified as POSW
import GraphOptimization.Traversals qualified as T
import Graphs.GraphOperations qualified as GO
import PHANE.Evaluation
import PHANE.Evaluation.ErrorPhase (ErrorPhase (..))
import PHANE.Evaluation.Logging (LogLevel (..), Logger (..))
import PHANE.Evaluation.Verbosity (Verbosity (..))
import Search.SwapV2 qualified as SV2
import Types.Types
import Utilities.LocalGraph qualified as LG
import Utilities.Utilities as U

--import Debug.Trace

{- | fuseAllGraphs takes a list of phylogenetic graphs and performs all pairwise fuses
later--could limit by options making random choices for fusing
keeps results according to options (best, unique, etc)
unique is unique of "best" from individual fusings
singleRound short circuits recursive continuation on newly found graphs
-}
fuseAllGraphs
    ∷ SwapParams
    → GlobalSettings
    → ProcessedData
    → Int
    → Bool
    → Bool
    → Bool
    → Maybe Int
    → Bool
    → Bool
    → Bool
    → [ReducedPhylogeneticGraph]
    → PhyG ([ReducedPhylogeneticGraph], Int)
fuseAllGraphs swapParams inGS inData counter returnBest returnUnique singleRound fusePairs randomPairs reciprocal maximizeParallel inGraphList = case inGraphList of
    [] → return ([], counter)
    [x] → return (inGraphList, counter)
    _ →
        let -- getting values to be passed for graph diagnorsis later
            numLeaves = V.length $ fst3 inData

            curBest = minimum $ fmap snd5 inGraphList

            curBestGraph = head $ filter ((== curBest) . snd5) inGraphList
        in  do
                -- get net penalty estimate from optimal graph for delta recombine later
                -- Nothing here so starts at overall root
                inGraphNetPenalty ← T.getPenaltyFactor inGS inData Nothing $ GO.convertReduced2PhylogeneticGraphSimple curBestGraph

                let inGraphNetPenaltyFactor = inGraphNetPenalty / curBest

                -- could be fusePairRecursive to save on memory
                let action ∷ (ReducedPhylogeneticGraph, ReducedPhylogeneticGraph) → PhyG [ReducedPhylogeneticGraph]
                    action = fusePair swapParams inGS inData numLeaves inGraphNetPenaltyFactor curBest reciprocal

                -- logWith LogInfo $ "FuAG: " <> (show (fusePairs, randomPairs))
                -- get fuse pairs
                let graphPairList' = getListPairs inGraphList
                (graphPairList, randString) ← case fusePairs of
                    Nothing → pure (graphPairList', "")
                    Just count | randomPairs → do
                        selectedGraphs ← take count <$> shuffleList graphPairList'
                        pure (selectedGraphs, " randomized")
                    Just index → pure (takeNth index graphPairList', "")

                let swapTypeString =
                        if swapType swapParams == NoSwap
                            then "out"
                            else " " <> (show $ swapType swapParams)

                logWith
                    LogInfo
                    ( "\tFusing "
                        <> (show $ length graphPairList)
                        <> randString
                        <> " graph pairs with"
                        <> swapTypeString
                        <> " swapping at minimum cost "
                        <> (show curBest)
                        <> "\n"
                    )
                      
                -- Option maximizeParallel will utilize more paralle but at cost of memory footprint
                -- defualt is False so uses mapM version                          
                newGraphList ←  if maximizeParallel then 
                                    getParallelChunkTraverseBy (fmap U.strict2of5) >>= \pTraverse →
                                        fold <$> pTraverse action graphPairList
                                else do
                                    result <- mapM (fusePair swapParams inGS inData numLeaves inGraphNetPenaltyFactor curBest reciprocal) graphPairList
                                    pure $ concat result

                let fuseBest =
                        if not (null newGraphList)
                            then minimum $ fmap snd5 newGraphList
                            else infinity

                if null newGraphList
                    then return (inGraphList, counter + 1)
                    else do
                        logWith LogInfo "\n"
                        if returnUnique
                            then do
                                uniqueList ← GO.selectGraphs Unique (outgroupIndex inGS) (keepNum swapParams) 0 $ inGraphList <> newGraphList
                                if fuseBest < curBest -- trace ("\t->" <> (show fuseBest)) --  <> "\n" <> (LG.prettify $ GO.convertDecoratedToSimpleGraph $ thd5 $ head bestSwapGraphList))
                                    then
                                        fuseAllGraphs
                                            swapParams
                                            inGS
                                            inData
                                            (counter + 1)
                                            returnBest
                                            returnUnique
                                            singleRound
                                            fusePairs
                                            randomPairs
                                            reciprocal
                                            maximizeParallel
                                            uniqueList
                                    else pure (uniqueList, counter + 1)
                            else -- return best
                            -- only do one round of fusing

                                if singleRound
                                    then GO.selectGraphs Best (outgroupIndex inGS) (keepNum swapParams) 0.0 (inGraphList <> newGraphList) <&> \x → (x, counter + 1)
                                    else -- recursive rounds
                                    do
                                        -- need unique list to keep going

                                        allBestList ← GO.selectGraphs Unique (outgroupIndex inGS) (keepNum swapParams) 0 $ inGraphList <> newGraphList
                                        -- found better
                                        if fuseBest < curBest
                                            then do
                                                -- logWith LogInfo ("\n")
                                                fuseAllGraphs
                                                    swapParams
                                                    inGS
                                                    inData
                                                    (counter + 1)
                                                    returnBest
                                                    returnUnique
                                                    singleRound
                                                    fusePairs
                                                    randomPairs
                                                    reciprocal
                                                    maximizeParallel
                                                    allBestList
                                            else -- equal or worse cost just return--could keep finding equal
                                                return (allBestList, counter + 1)


{- | fusePairRecursive wraps around fusePair recursively traversing through fuse pairs as oppose
to parMapping at once creating a large memory footprint
needs to be refactored (left right are same)

-- this logic is wrong and needs to be fixed

fusePairRecursive
    ∷ SwapParams
    → GlobalSettings
    → ProcessedData
    → Int
    → VertexCost
    → VertexCost
    → Bool
    → [ReducedPhylogeneticGraph]
    → [(ReducedPhylogeneticGraph, ReducedPhylogeneticGraph)]
    → PhyG [ReducedPhylogeneticGraph]
fusePairRecursive swapParams inGS inData numLeaves netPenalty curBestScore reciprocal resultList leftRightList =
    if null leftRightList
        then return resultList
        else
            let -- parallel here blows up memory
                numPairsToExamine = graphsSteepest inGS -- min (graphsSteepest inGS) PU.getNumThreads

                -- parallel setup
                action ∷ (ReducedPhylogeneticGraph, ReducedPhylogeneticGraph) → PhyG [ReducedPhylogeneticGraph]
                action = fusePair swapParams inGS inData numLeaves netPenalty curBestScore reciprocal
            in  do
                    -- paralleized high level
                    fusePairResult' ←
                        getParallelChunkTraverseBy (fmap U.strict2of5) >>= \pTraverse →
                            action `pTraverse` take numPairsToExamine leftRightList
                    let fusePairResult = concat fusePairResult'

                    bestResultList ←
                        if graphType inGS == Tree
                            then GO.selectGraphs Best (outgroupIndex inGS) (keepNum swapParams) 0 fusePairResult
                            else do
                                -- check didn't make weird network
                                goodGraphList ← filterM (LG.isPhylogeneticGraph . fst5) fusePairResult
                                GO.selectGraphs Best (outgroupIndex inGS) (keepNum swapParams) 0 goodGraphList

                    let pairScore =
                            if (not . null) bestResultList
                                then snd5 $ head bestResultList
                                else infinity

                    let newCurBestScore = min curBestScore pairScore

                    bestResultList' ←
                        fusePairRecursive
                            swapParams
                            inGS
                            inData
                            numLeaves
                            netPenalty
                            newCurBestScore
                            reciprocal
                            resultList
                            (drop numPairsToExamine leftRightList)

                    let bestResultList'' =
                            if pairScore <= curBestScore
                                then bestResultList'
                                else []

                    pure bestResultList''
-}

-- bestResultList' <> fusePairRecursive swapParams inGS inData numLeaves netPenalty newCurBestScore reciprocal resultList (tail leftRightList)

{- | fusePair recombines a single pair of graphs
this is done by coopting the split and readd functinos from the Swap.Swap functions and exchanging
pruned subgraphs with the same leaf complement (as recorded by the subtree root node bit vector field)
spr-like and tbr-like readds can be performed as with options
needs simolification and refactoring
-}
fusePair
    ∷ SwapParams
    → GlobalSettings
    → ProcessedData
    → Int
    → VertexCost
    → VertexCost
    → Bool
    → (ReducedPhylogeneticGraph, ReducedPhylogeneticGraph)
    → PhyG [ReducedPhylogeneticGraph]
fusePair swapParams inGS inData numLeaves netPenalty curBestScore reciprocal (leftGraph, rightGraph) =
    if (LG.isEmpty $ fst5 leftGraph) || (LG.isEmpty $ fst5 rightGraph)
        then error "Empty graph in fusePair"
        else
            if (fst5 leftGraph) == (fst5 rightGraph)
                then return []
                else -- split graphs at all bridge edges (all edges for Tree)

                    let -- left graph splits on all edges
                        leftDecoratedGraph = thd5 leftGraph
                        (leftRootIndex, _) = head $ LG.getRoots leftDecoratedGraph
                        leftBreakEdgeList =
                            if (graphType inGS) == Tree
                                then filter ((/= leftRootIndex) . fst3) $ LG.labEdges leftDecoratedGraph
                                else filter ((/= leftRootIndex) . fst3) $ LG.getEdgeSplitList leftDecoratedGraph

                        -- right graph splits on all edges
                        rightDecoratedGraph = thd5 rightGraph
                        (rightRootIndex, _) = head $ LG.getRoots rightDecoratedGraph
                        rightBreakEdgeList =
                            if (graphType inGS) == Tree
                                then filter ((/= rightRootIndex) . fst3) $ LG.labEdges rightDecoratedGraph
                                else filter ((/= rightRootIndex) . fst3) $ LG.getEdgeSplitList rightDecoratedGraph

                        -- parallel stuff
                        --splitLeftAction :: (Show b) => LG.Gr a b -> LG.LEdge b -> (LG.Gr a b, LG.Node, LG.Node, LG.Node, LG.LEdge b, [LG.Edge])
                        splitLeftAction = LG.splitGraphOnEdge' leftDecoratedGraph

                        -- splitRightAction :: (Show b) => Gr a b -> LEdge b -> (Gr a b, Node, Node, Node, LEdge b, [Edge])
                        splitRightAction = LG.splitGraphOnEdge' rightDecoratedGraph

                        exchangeAction
                            ∷ ((DecoratedGraph, LG.Node, LG.Node, LG.Node), (DecoratedGraph, LG.Node, LG.Node, LG.Node), LG.Node)
                            → (DecoratedGraph, Int, Int, Int, Int)
                        exchangeAction = exchangePrunedGraphs numLeaves

                        --Issues with the new reoptimize--made too many assumptions and need to revisit.
                        --reoptimizeActionNew ∷ (PhylogeneticGraph, DecoratedGraph, LG.Node, LG.Node) → PhyG (DecoratedGraph, VertexCost)
                        --reoptimizeActionNew = SV2.reoptimizeSplitGraphFromVertexTupleNew swapParams inGS inData False (U.getNumberSequenceCharacters $ thd3 inData) netPenalty

                        reoptimizeAction ∷ (DecoratedGraph, Int, Int) → PhyG (DecoratedGraph, VertexCost)
                        reoptimizeAction = SV2.reoptimizeSplitGraphFromVertexTupleFuse inGS inData False netPenalty
                        
                    in  do
                            splitLeftPar ← getParallelChunkMap
                            let leftSplitTupleList = splitLeftPar splitLeftAction leftBreakEdgeList

                            let (_, _, leftPrunedGraphRootIndexList, leftOriginalConnectionOfPrunedList, leftOriginalEdgeList, _) = L.unzip6 leftSplitTupleList

                            let leftPrunedGraphBVList = fmap bvLabel $ fmap fromJust $ fmap (LG.lab leftDecoratedGraph) leftPrunedGraphRootIndexList

                            splitRightPar ← getParallelChunkMap
                            let rightSplitTupleList = splitRightPar splitRightAction rightBreakEdgeList

                            let (_, _, rightPrunedGraphRootIndexList, rightOriginalConnectionOfPrunedList, rightOriginalEdgeList, _) = L.unzip6 rightSplitTupleList

                            let rightPrunedGraphBVList = fmap bvLabel $ fmap fromJust $ fmap (LG.lab rightDecoratedGraph) rightPrunedGraphRootIndexList

                            -- get all pairs of split graphs
                            let (leftSplitTupleList', rightSplitTupleList') = unzip $ cartProd (fmap first4of6 leftSplitTupleList) (fmap first4of6 rightSplitTupleList)
                            let (leftPrunedGraphBVList', rightPrunedGraphBVList') = unzip $ cartProd leftPrunedGraphBVList rightPrunedGraphBVList

                            -- get compatible split pairs via checking bv of root index of pruned subgraphs
                            let leftRightMatchList = zipWith (==) leftPrunedGraphBVList' rightPrunedGraphBVList'

                            -- only take compatible, non-identical pairs with > 2 terminal--otherwise basically SPR move or nothing (if identical)
                            -- also checks that prune and splits don't match between the graphs to be recombined--ie exchanging the same sub-graph
                            let recombinablePairList = L.zipWith (getCompatibleNonIdenticalSplits numLeaves) leftRightMatchList leftPrunedGraphBVList'
                            let (leftValidTupleList, rightValidTupleList, _) = L.unzip3 $ filter ((== True) . thd3) $ zip3 leftSplitTupleList' rightSplitTupleList' recombinablePairList

                            if null leftValidTupleList
                                then pure []
                                else do
                                    -- create new "splitgraphs" by replacing nodes and edges of pruned subgraph in reciprocal graphs
                                    -- returns reindexed list of base graph root, pruned component root,  parent of pruned component root, original graph break edge

                                    -- leftRight first then rightLeft if reciprocal
                                    -- logWith LogInfo $ "Doing left right"
                                                
                                    exchangeLeftPar ← getParallelChunkMap
                                    let exchangeLeftResult = exchangeLeftPar exchangeAction (zip3 leftValidTupleList rightValidTupleList leftOriginalConnectionOfPrunedList)
                                    let ( leftBaseRightPrunedSplitGraphList
                                            , leftRightGraphRootIndexList
                                            , leftRightPrunedParentRootIndexList
                                            , leftRightPrunedRootIndexList
                                            , leftRightOriginalConnectionOfPrunedList
                                            ) =
                                                L.unzip5 exchangeLeftResult

                                    leftRightOptimizedSplitGraphCostList ←
                                        getParallelChunkTraverseBy U.strict2of2 >>= \pTraverse →
                                            -- need to revisit to make a better incremental optimization here
                                            pTraverse reoptimizeAction $ L.zip3 leftBaseRightPrunedSplitGraphList leftRightGraphRootIndexList leftRightPrunedRootIndexList

                                    let baseGraphDifferentList = L.replicate (length leftRightOptimizedSplitGraphCostList) True

                                    let ( _
                                            , leftRightOptimizedSplitGraphCostList'
                                            , _
                                            , leftRightPrunedRootIndexList'
                                            , leftRightPrunedParentRootIndexList'
                                            , leftRightOriginalConnectionOfPrunedList'
                                            ) =
                                                L.unzip6 $
                                                    filter ((== True) . fst6) $
                                                        L.zip6
                                                            baseGraphDifferentList
                                                            leftRightOptimizedSplitGraphCostList
                                                            leftRightGraphRootIndexList
                                                            leftRightPrunedRootIndexList
                                                            leftRightPrunedParentRootIndexList
                                                            leftRightOriginalConnectionOfPrunedList

                                    -- re-add pruned component to base component left-right and right-left
                                    -- need curent best cost
                                    let curBetterCost = min (snd5 leftGraph) (snd5 rightGraph)

                                    -- get network penalty factors to pass on
                                    leftPenalty ← getNetworkPentaltyFactor inGS inData (snd5 leftGraph) leftGraph
                                    rightPenalty ← getNetworkPentaltyFactor inGS inData (snd5 rightGraph) rightGraph
                                    let networkCostFactor = min leftPenalty rightPenalty

                                    -- left and right root indices should be the same
                                    leftRightFusedGraphList ←
                                        recombineComponents
                                            swapParams
                                            inGS
                                            inData
                                            curBetterCost
                                            curBestScore
                                            leftRightOptimizedSplitGraphCostList'
                                            leftRightPrunedRootIndexList'
                                            leftRightPrunedParentRootIndexList'
                                            leftRightOriginalConnectionOfPrunedList'
                                            leftRootIndex
                                            networkCostFactor
                                            leftOriginalEdgeList

                                    rightLeftFusedGraphList ←
                                        if not reciprocal
                                            then pure []
                                            else do
                                                -- logWith LogInfo $ "Doing right left "
                                                exchangeRightPar ← getParallelChunkMap
                                                let exchangeRightResult = exchangeRightPar exchangeAction (zip3 rightValidTupleList leftValidTupleList rightOriginalConnectionOfPrunedList)
                                                let ( rightBaseLeftPrunedSplitGraphList
                                                        , rightLeftGraphRootIndexList
                                                        , rightLeftPrunedParentRootIndexList
                                                        , rightLeftPrunedRootIndexList
                                                        , rightLeftOriginalConnectionOfPrunedList
                                                        ) =
                                                            L.unzip5 exchangeRightResult

                                                rightLeftOptimizedSplitGraphCostList ←
                                                    getParallelChunkTraverseBy U.strict2of2 >>= \pTraverse →
                                                    -- need to revisit to make a better incremental optimization here
                                                    -- pTraverse reoptimizeActionNew $ L.zip4 (L.replicate (length rightBaseLeftPrunedSplitGraphList) $ GO.convertReduced2PhylogeneticGraph rightGraph) rightBaseLeftPrunedSplitGraphList rightLeftGraphRootIndexList rightLeftPrunedRootIndexList
                                                    pTraverse reoptimizeAction $ L.zip3 rightBaseLeftPrunedSplitGraphList rightLeftGraphRootIndexList rightLeftPrunedRootIndexList

                                                let ( _
                                                        , rightLeftOptimizedSplitGraphCostList'
                                                        , _
                                                        , rightLeftPrunedRootIndexList'
                                                        , rightLeftPrunedParentRootIndexList'
                                                        , rightLeftOriginalConnectionOfPrunedList'
                                                        ) =
                                                            L.unzip6 $
                                                                filter ((== True) . fst6) $
                                                                    L.zip6
                                                                        baseGraphDifferentList
                                                                        rightLeftOptimizedSplitGraphCostList
                                                                        rightLeftGraphRootIndexList
                                                                        rightLeftPrunedRootIndexList
                                                                        rightLeftPrunedParentRootIndexList
                                                                        rightLeftOriginalConnectionOfPrunedList
                                                recombineComponents
                                                    swapParams
                                                    inGS
                                                    inData
                                                    curBetterCost
                                                    curBestScore
                                                    rightLeftOptimizedSplitGraphCostList'
                                                    rightLeftPrunedRootIndexList'
                                                    rightLeftPrunedParentRootIndexList'
                                                    rightLeftOriginalConnectionOfPrunedList'
                                                    rightRootIndex
                                                    networkCostFactor
                                                    rightOriginalEdgeList

                                    -- get "best" fused graphs from leftRight and rightLeft
                                    bestFusedGraphs ← GO.selectGraphs Best (outgroupIndex inGS) (keepNum swapParams) 0 $ leftRightFusedGraphList <> rightLeftFusedGraphList

                                    pure bestFusedGraphs
    where
        first4of6 (a, b, c, d, _, _) = (a, b, c, d)


{- | recombineComponents takes readdition arguments (swap, steepest etc) and wraps the swap-stype rejoining of components
ignores doSteepeast for now--doesn't seem to have meaning in rejoining since not then taking that graph for fusion and shortcircuiting
original connection done first left/rightOriginalEdgeList--spo can do "none" in swap
"curBetterCost" is of pain of inputs to make sure keep all better than their inputs, "overallBestScore" is for progress info
-}
recombineComponents
    ∷ SwapParams
    → GlobalSettings
    → ProcessedData
    → VertexCost
    → VertexCost
    → [(DecoratedGraph, VertexCost)]
    → [Int]
    → [Int]
    → [Int]
    → LG.Node
    → VertexCost
    → [LG.LEdge EdgeInfo]
    → PhyG [ReducedPhylogeneticGraph]
recombineComponents swapParams inGS inData curBetterCost overallBestCost inSplitGraphCostPairList prunedRootIndexList prunedParentRootIndexList _ graphRoot networkCostFactor originalSplitEdgeList =
    -- check and see if any reconnecting to do
    -- trace ("RecombineComponents " <> (show $ length splitGraphCostPairList)) (
    let splitGraphCostPairList = filter ((not . LG.isEmpty) . fst) inSplitGraphCostPairList
    in  if null splitGraphCostPairList
            then pure []
            else -- top line to cover SPR HarWired bug

                let -- since splits not created together, IA won't be consistent between components
                    -- steepest = False -- should look at all better, now option

                    -- network costs--using an input value that is minimum of inputs
                    netPenaltyFactorList = L.replicate (length splitGraphCostPairList) networkCostFactor

                    -- no simulated annealling functionality infuse
                    inSimAnnealParams = Nothing

                    -- get edges in pruned (to be exchanged) graphs
                    edgesInPrunedList = fmap LG.getEdgeListAfter $ zip (fmap fst splitGraphCostPairList) prunedParentRootIndexList

                    -- get edges in base (not to be exchanged) graphs and put original split edge first
                    rejoinEdgesList = fmap (getBaseGraphEdges graphRoot) $ zip3 (fmap fst splitGraphCostPairList) edgesInPrunedList originalSplitEdgeList

                    -- huge zip to fit arguments into revised join function
                    graphDataList =
                        zip9
                            (fmap fst splitGraphCostPairList)
                            (fmap GO.convertDecoratedToSimpleGraph $ fmap fst splitGraphCostPairList)
                            (fmap snd splitGraphCostPairList)
                            (L.replicate (length splitGraphCostPairList) graphRoot)
                            prunedRootIndexList
                            prunedParentRootIndexList
                            rejoinEdgesList
                            edgesInPrunedList
                            netPenaltyFactorList

                    -- parallel setup
                    action
                        ∷ (DecoratedGraph, SimpleGraph, VertexCost, LG.Node, LG.Node, LG.Node, [LG.LEdge EdgeInfo], [LG.LEdge EdgeInfo], VertexCost)
                        → PhyG [ReducedPhylogeneticGraph]
                    action = SV2.rejoinGraphTuple swapParams inGS inData overallBestCost [] inSimAnnealParams
                in  -- alternate -- rejoinGraphTupleRecursive swapParams inGS inData curBetterCost overallBestCost inSimAnnealParams graphDataList
                    do
                        --logWith LogInfo $ "RC: " <> (show $ length graphDataList)
                        -- do "all additions" -
                        recombinedGraphList' ← getParallelChunkTraverseBy (fmap U.strict2of5) >>= \pTraverse → pTraverse action graphDataList
                        let recombinedGraphList = concat recombinedGraphList'

                        -- this based on heuristic deltas
                        let bestFuseCost =
                                if null recombinedGraphList
                                    then infinity
                                    else minimum $ fmap snd5 recombinedGraphList
                        if null recombinedGraphList
                            then pure []
                            else
                                if bestFuseCost <= curBetterCost
                                    then GO.selectGraphs Best (outgroupIndex inGS) (keepNum swapParams) 0 recombinedGraphList
                                    else pure []


{- | rejoinGraphTupleRecursive is a wrapper for SV2.rejoinGraphTuple that recursively goes through list as opposd to parMapping
this to save on memory footprint since there would be many calls generated
the rejoin operation is parallelized itself
recursive best cost so can keep all better than input but can have progress info
-}
rejoinGraphTupleRecursive
    ∷ SwapParams
    → GlobalSettings
    → ProcessedData
    → VertexCost
    → VertexCost
    → Maybe SAParams
    → [(DecoratedGraph, SimpleGraph, VertexCost, LG.Node, LG.Node, LG.Node, [LG.LEdge EdgeInfo], [LG.LEdge EdgeInfo], VertexCost)]
    → PhyG [ReducedPhylogeneticGraph]
rejoinGraphTupleRecursive swapParams inGS inData curBestCost recursiveBestCost inSimAnnealParams graphDataList =
    if null graphDataList
        then return []
        else
            let firstGraphData = head graphDataList
                -- update with unions for rejoining
                -- using best cost for differentiate since there was no single graph to get original deltas
                -- add randomize edges option?

                firstGraphData' = firstGraphData
            in  {-Turned off for now since doesn't alternate
                if joinType swapParams /= JoinAll then
                  (splitGraphDec, splitGraphSimple, splitCost, baseGraphRootIndex, prunedGraphRootIndex, prunedParentRootIndex, unionEdgeList, edgesInPrunedList, netPenaltyFactor)
                else firstGraphData
                -}

                -- Unconditional printing, conditional output payload.
                do
                    firstRejoinResult ← SV2.rejoinGraphTuple swapParams inGS inData curBestCost [] inSimAnnealParams firstGraphData'
                    let firstBestCost =
                            if (not . null) firstRejoinResult
                                then minimum $ fmap snd5 firstRejoinResult
                                else infinity

                    let newRecursiveBestCost = min recursiveBestCost firstBestCost

                    when (firstBestCost < recursiveBestCost) $
                        logWith LogInfo ("\t->" <> show newRecursiveBestCost)

                    rejoinResult ←
                        rejoinGraphTupleRecursive swapParams inGS inData curBestCost newRecursiveBestCost inSimAnnealParams (tail graphDataList)
                    let result = firstRejoinResult <> rejoinResult

                    pure result


{-
      -- Doing a conditional print like this still results in a <<loop>> exception
      -- This is a really confision and cryptic  error condition,
      -- however it is 100% related to unsafe printing and parallelism.
      -- So we gotta refactor to do logging properly and then refactor to correctly
      -- enable parallism in order to fully address this class of issues!

      in  if firstBestCost < recursiveBestCost
          then trace ("\t->" <> show newRecursiveBestCost) result
          else result
-}

-- | getNetworkPentaltyFactor get scale network penalty for graph
getNetworkPentaltyFactor ∷ GlobalSettings → ProcessedData → VertexCost → ReducedPhylogeneticGraph → PhyG VertexCost
getNetworkPentaltyFactor inGS inData graphCost inGraph =
    if LG.isEmpty $ thd5 inGraph
        then pure 0.0
        else do
            inGraphNetPenalty ←
                if (graphType inGS == Tree)
                    then pure 0.0
                    else -- else if (graphType inGS == HardWired) then 0.0

                        if (graphFactor inGS) == NoNetworkPenalty
                            then pure 0.0
                            else
                                if (graphFactor inGS) == Wheeler2015Network
                                    then POSW.getW15NetPenaltyFull Nothing inGS inData Nothing (GO.convertReduced2PhylogeneticGraphSimple inGraph)
                                    else
                                        if (graphFactor inGS) == Wheeler2023Network
                                            then pure $ POSW.getW23NetPenaltyReduced inGraph
                                            else error ("Network penalty type " <> (show $ graphFactor inGS) <> " is not yet implemented")

            pure $ inGraphNetPenalty / graphCost


{- | getBaseGraphEdges gets the edges in the base graph the the exchanged sub graphs can be rejoined
basically all edges except at root and those in the subgraph
adds original edge connection edges (those with nodes in original edge) at front (for use in "none" swap later), removing if there to
prevent redundancy if swap not "none"
-}
getBaseGraphEdges ∷ (Eq b) ⇒ LG.Node → (LG.Gr a b, [LG.LEdge b], LG.LEdge b) → [LG.LEdge b]
getBaseGraphEdges graphRoot (inGraph, edgesInSubGraph, origSiteEdge) =
    if LG.isEmpty inGraph
        then []
        else
            let baseGraphEdges = filter ((/= graphRoot) . fst3) $ (LG.labEdges inGraph) L.\\ edgesInSubGraph
                baseMatchList = filter (edgeMatch origSiteEdge) baseGraphEdges
            in  -- origSiteEdge : (filter ((/= graphRoot) . fst3) $ (LG.labEdges inGraph) L.\\ (origSiteEdge : edgesInSubGraph))

                -- trace ("GBGE: " <> (show $ length baseMatchList))
                -- trace ("GBGE sub: " <> (show $ origEdge `elem` (fmap LG.toEdge edgesInSubGraph)) <> " base: " <> (show $ origEdge `elem` (fmap LG.toEdge baseGraphEdges)) <> " total: " <> (show $ origEdge `elem` (fmap LG.toEdge $ LG.labEdges inGraph)) <> "\n" <> (show origEdge) <> " sub " <> (show $ fmap LG.toEdge edgesInSubGraph) <> " base " <> (show $ fmap LG.toEdge baseGraphEdges) <> "\nTotal " <> (show $ fmap LG.toEdge $ LG.labEdges inGraph))

                baseMatchList <> (baseGraphEdges L.\\ baseMatchList)
    where
        edgeMatch (a, b, _) (e, v, _) =
            if e == a
                then True
                else
                    if e == b
                        then True
                        else
                            if v == a
                                then True
                                else
                                    if v == b
                                        then True
                                        else False


{- | getCompatibleNonIdenticalSplits takes the number of leaves, splitGraph of the left graph, the splitGraph if the right graph,
the bitVector equality list of pruned roots, the bitvector of the root of the pruned graph on left
(this could be either since filter for identity--just to check leaf numbers)
checks that the leaf sets of the pruned subgraphs are equal, greater than 1 leaf, fewer thanm nleaves - 2, and non-identical
removed identity check fo now--so much time to do that (O(n)) may not be worth it
-}
getCompatibleNonIdenticalSplits
    ∷ Int
    → Bool
    → BV.BitVector
    → Bool
getCompatibleNonIdenticalSplits numLeaves leftRightMatch leftPrunedGraphBV
    | not leftRightMatch = False
    | popCount leftPrunedGraphBV < 3 = False
    | popCount leftPrunedGraphBV > numLeaves - 3 = False
    | otherwise = True


{- | exchangePrunedGraphs creates a new "splitGraph" containing both first (base) and second (pruned) graph components
both components need to have HTU and edges reindexed to be in sync, oringal edge terminal node is also reindexed and returned for limit readd distance
-}
exchangePrunedGraphs
    ∷ Int
    → ((DecoratedGraph, LG.Node, LG.Node, LG.Node), (DecoratedGraph, LG.Node, LG.Node, LG.Node), LG.Node)
    → (DecoratedGraph, Int, Int, Int, Int)
exchangePrunedGraphs numLeaves (firstGraphTuple, secondGraphTuple, breakEdgeNode) =
    if LG.isEmpty (fst4 firstGraphTuple) || LG.isEmpty (fst4 secondGraphTuple)
        then
            error
                ("Empty graph input in exchangePrunedGraphs" <> (show (LG.isEmpty (fst4 firstGraphTuple), LG.isEmpty (fst4 secondGraphTuple))))
        else
            let (firstSplitGraph, firstGraphRootIndex, _, _) = firstGraphTuple
                (secondSplitGraph, _, secondPrunedGraphRootIndex, _) = secondGraphTuple

                -- get nodes and edges of firstBase
                firstGraphRootLabel = fromJust $ LG.lab firstSplitGraph firstGraphRootIndex
                firstGraphRootNode = (firstGraphRootIndex, firstGraphRootLabel)
                (firstBaseGraphNodeList', firstBaseGraphEdgeList) = LG.nodesAndEdgesAfter firstSplitGraph [firstGraphRootNode]

                -- add in root nodes of partitions since not included in "nodesAfter" function
                firstBaseGraphNodeList = firstGraphRootNode : firstBaseGraphNodeList'

                -- get nodes and edges of second pruned
                secondPrunedGraphRootLabel = fromJust $ LG.lab secondSplitGraph secondPrunedGraphRootIndex
                secondPrunedGraphRootNode = (secondPrunedGraphRootIndex, secondPrunedGraphRootLabel)
                secondPrunedParentNode = head $ LG.labParents secondSplitGraph secondPrunedGraphRootIndex
                (secondPrunedGraphNodeList', secondPrunedGraphEdgeList') = LG.nodesAndEdgesAfter secondSplitGraph [secondPrunedGraphRootNode]

                -- add root node of second pruned since not included in "nodesAfter" function
                -- add in gandparent nodes of pruned and its edges to pruned graphs
                secondPrunedGraphNodeList = [secondPrunedGraphRootNode, secondPrunedParentNode] <> secondPrunedGraphNodeList'
                secondPrunedGraphEdgeList = (head $ LG.inn secondSplitGraph secondPrunedGraphRootIndex) : secondPrunedGraphEdgeList'

                -- reindex base and pruned partitions (HTUs and edges) to get in sync and make combinable
                -- 0 is dummy since won't be in base split
                (baseGraphNodes, baseGraphEdges, numBaseHTUs, reindexedBreakEdgeNodeBase) = reindexSubGraph numLeaves 0 firstBaseGraphNodeList firstBaseGraphEdgeList breakEdgeNode
                (prunedGraphNodes, prunedGraphEdges, _, _) = reindexSubGraph numLeaves numBaseHTUs secondPrunedGraphNodeList secondPrunedGraphEdgeList breakEdgeNode

                -- should always be in base graph--should be in first (base) component--if not use original node
                reindexedBreakEdgeNode =
                    if (reindexedBreakEdgeNodeBase /= Nothing)
                        then fromJust reindexedBreakEdgeNodeBase
                        else breakEdgeNode

                -- create and reindex new split graph
                newSplitGraph = LG.mkGraph (baseGraphNodes <> prunedGraphNodes) (baseGraphEdges <> prunedGraphEdges)

                -- get graph root Index, pruned root index, pruned root parent index
                -- firstGraphRootIndex should not have changed in reindexing--same as numLeaves
                prunedParentRootIndex = fst $ head $ (LG.getRoots newSplitGraph) L.\\ [firstGraphRootNode]
                prunedRootIndex = head $ LG.descendants newSplitGraph prunedParentRootIndex
            in  if (length $ LG.getRoots newSplitGraph) /= 2
                    then error ("Not 2 components in split graph: " <> "\n" <> (LG.prettify $ GO.convertDecoratedToSimpleGraph newSplitGraph))
                    else
                        if (length $ LG.descendants newSplitGraph prunedParentRootIndex) /= 1
                            then error ("Too many children of parentPrunedNode: " <> "\n" <> (LG.prettify $ GO.convertDecoratedToSimpleGraph newSplitGraph))
                            else
                                if (length $ LG.parents secondSplitGraph secondPrunedGraphRootIndex) /= 1
                                    then
                                        error
                                            ( "Parent number not equal to 1 in node "
                                                <> (show secondPrunedGraphRootIndex)
                                                <> " of second graph\n"
                                                <> (LG.prettify $ GO.convertDecoratedToSimpleGraph secondSplitGraph)
                                            )
                                    else
                                        if (length $ LG.inn secondSplitGraph secondPrunedGraphRootIndex) /= 1
                                            then
                                                error
                                                    ( "Edge incedent tor pruned graph not equal to 1 in node "
                                                        <> (show $ fmap LG.toEdge $ LG.inn secondSplitGraph secondPrunedGraphRootIndex)
                                                        <> " of second graph\n"
                                                        <> (LG.prettify $ GO.convertDecoratedToSimpleGraph secondSplitGraph)
                                                    )
                                            else (newSplitGraph, firstGraphRootIndex, prunedParentRootIndex, prunedRootIndex, reindexedBreakEdgeNode)


{- | reindexSubGraph reindexes the non-leaf nodes and edges of a subgraph to allow topological combination of subgraphs
the leaf indices are unchanges but HTUs are changes ot in order enumeration statting with an input offset
new BreakEdge is returned as a Maybe becuase may be either in base or pruned subgraphs
-}
reindexSubGraph
    ∷ Int → Int → [LG.LNode VertexInfo] → [LG.LEdge b] → LG.Node → ([LG.LNode VertexInfo], [LG.LEdge b], Int, Maybe LG.Node)
reindexSubGraph numLeaves offset nodeList edgeList origBreakEdge =
    if null nodeList || null edgeList
        then ([], [], offset, Nothing)
        else -- create map of node indices from list

            let (newNodeList, indexList) = unzip $ getPairList numLeaves offset nodeList
                indexMap = MAP.fromList indexList
                newEdgeList = fmap (reIndexEdge indexMap) edgeList
                newBreakEdge = MAP.lookup origBreakEdge indexMap
            in  {-
                if newBreakEdge == Nothing then error  ("Map index for break edge node not found: " <> (show origBreakEdge) <> " in Map " <> (show $ MAP.toList indexMap))
                else
                -}
                -- trace ("RISG:" <> (show (fmap fst nodeList, fmap fst newNodeList, numLeaves)) <> " map " <> (show $ MAP.toList indexMap))
                (newNodeList, newEdgeList, 1 + (maximum $ fmap fst newNodeList) - numLeaves, newBreakEdge)


-- | reIndexEdge takes a map and a labelled edge and returns new indices same label edge based on map
reIndexEdge ∷ MAP.Map Int Int → LG.LEdge b → LG.LEdge b
reIndexEdge indexMap (u, v, l) =
    let u' = MAP.lookup u indexMap
        v' = MAP.lookup v indexMap
    in  if u' == Nothing || v' == Nothing
            then error ("Error in map lookup in reindexEdge: " <> show (u, v))
            else (fromJust u', fromJust v', l)


{- | getPairList returns an original index new index lits of pairs
assumes leaf nmodes are first numleaves
-}
getPairList ∷ Int → Int → [LG.LNode VertexInfo] → [(LG.LNode VertexInfo, (Int, Int))]
getPairList numLeaves counter nodeList =
    if null nodeList
        then []
        else
            let (firstIndex, firstLabel) = head nodeList
                newLabel = firstLabel{vertName = TL.pack ("HTU" <> (show $ counter + numLeaves))}
            in  if firstIndex < numLeaves
                    then (head nodeList, (firstIndex, firstIndex)) : getPairList numLeaves counter (tail nodeList)
                    else ((counter + numLeaves, newLabel), (firstIndex, (counter + numLeaves))) : getPairList numLeaves (counter + 1) (tail nodeList)
