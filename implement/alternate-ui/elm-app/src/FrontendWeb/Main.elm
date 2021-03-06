module FrontendWeb.Main exposing (Event(..), State, init, main, update, view)

import Browser
import Browser.Navigation as Navigation
import Dict
import File
import File.Download
import File.Select
import Html
import Html.Attributes as HA
import Html.Events as HE
import Http
import InterfaceToFrontendClient
import Json.Decode
import Json.Encode
import Sanderling.Sanderling
import Set
import String.Extra
import Task
import Time
import Url


main =
    Browser.application
        { init = init
        , update = update
        , subscriptions = subscriptions
        , view = view
        , onUrlRequest = UrlRequest
        , onUrlChange = UrlChange
        }


type alias State =
    { navigationKey : Navigation.Key
    , selectedSource : MemoryReadingSource
    , readFromFileResult : Maybe ParseMemoryReadingCompleted
    , readFromLiveProcess : ReadFromLiveProcessState
    , treeView : TreeViewState
    }


type alias ReadFromLiveProcessState =
    { readEveOnlineClientProcessesIdsResult : Maybe (Result String (Set.Set Int))
    , readMemoryResult : Maybe (Result String ReadFromLiveProcessCompleted)
    }


type alias ReadFromLiveProcessCompleted =
    { mainWindowId : String
    , memoryReading : ParseMemoryReadingCompleted
    }


type alias ParseMemoryReadingCompleted =
    { partialPythonJson : String
    , parseResult : Result Json.Decode.Error ParseMemoryReadingSuccess
    }


type alias ParseMemoryReadingSuccess =
    { uiTree : MemoryReadingUITreeNode
    , overviewWindow : MaybeVisible OverviewWindow
    }


type MemoryReadingSource
    = FromLiveProcess
    | FromFile


type Event
    = BackendResponse { request : InterfaceToFrontendClient.RequestFromClient, result : Result Http.Error ResponseFromServer }
    | UrlRequest Browser.UrlRequest
    | UrlChange Url.Url
    | UserInputSelectMemoryReadingSource MemoryReadingSource
    | UserInputSelectMemoryReadingFile (Maybe File.File)
    | ReadMemoryReadingFile String
    | UserInputSetTreeViewNodeIsExpanded ExpandableViewNode Bool
    | ContinueReadFromLiveProcess
    | UserInputDownloadJsonFile String


type alias MemoryReadingUITreeNode =
    { originalJson : Json.Encode.Value
    , pythonObjAddress : Int
    , pythonObjTypeName : String
    , children : Maybe (List MemoryReadingUITreeNodeChild)
    , otherProperties : List ( String, Json.Encode.Value )
    }


type MemoryReadingUITreeNodeChild
    = MemoryReadingUITreeNodeChild
        { originalJson : Json.Encode.Value
        , pythonObjAddress : Int
        , pythonObjTypeName : String
        , children : Maybe (List MemoryReadingUITreeNodeChild)
        , otherProperties : List ( String, Json.Encode.Value )
        }


type alias TreeViewState =
    { expandedNodes : List ExpandableViewNode
    }


type ExpandableViewNode
    = ExpandableUITreeNode UITreeNodeIdentity
    | ExpandableUITreeNodeChildren UITreeNodeIdentity


type alias UITreeNodeIdentity =
    { pythonObjAddress : Int }


type ResponseFromServer
    = RunInVolatileHostResponse InterfaceToFrontendClient.RunInVolatileHostResponseStructure
    | ReadLogResponse (List String)


type alias OverviewWindow =
    { headers : List String
    , entries : List OverviewEntry
    }


type alias OverviewEntry =
    { uiTreeNode : MemoryReadingUITreeNode
    , cellsContents : Dict.Dict String String
    }


type MaybeVisible feature
    = CanNotSeeIt
    | CanSee feature


subscriptions : State -> Sub Event
subscriptions state =
    case state.selectedSource of
        FromFile ->
            Sub.none

        FromLiveProcess ->
            Time.every 1000 (always ContinueReadFromLiveProcess)


init : () -> Url.Url -> Navigation.Key -> ( State, Cmd Event )
init _ url navigationKey =
    { navigationKey = navigationKey
    , selectedSource = FromFile
    , readFromLiveProcess =
        { readEveOnlineClientProcessesIdsResult = Nothing
        , readMemoryResult = Nothing
        }
    , readFromFileResult = Nothing
    , treeView = { expandedNodes = [] }
    }
        |> update (UrlChange url)


apiRequestCmd : InterfaceToFrontendClient.RequestFromClient -> Cmd Event
apiRequestCmd request =
    let
        responseDecoder =
            case request of
                InterfaceToFrontendClient.ReadLogRequest ->
                    -- TODO
                    Json.Decode.succeed (ReadLogResponse [])

                InterfaceToFrontendClient.RunInVolatileHostRequest _ ->
                    InterfaceToFrontendClient.jsonDecodeRunInVolatileHostResponseStructure
                        |> Json.Decode.map RunInVolatileHostResponse
    in
    Http.post
        { url = "/api/"
        , expect = Http.expectJson (\result -> BackendResponse { request = request, result = result }) responseDecoder
        , body = Http.jsonBody (request |> InterfaceToFrontendClient.jsonEncodeRequestFromClient)
        }


update : Event -> State -> ( State, Cmd Event )
update event stateBefore =
    case event of
        BackendResponse { request, result } ->
            ( stateBefore |> integrateBackendResponse { request = request, result = result }, Cmd.none )

        UrlChange url ->
            ( stateBefore, Cmd.none )

        UrlRequest urlRequest ->
            case urlRequest of
                Browser.Internal url ->
                    ( stateBefore, Navigation.pushUrl stateBefore.navigationKey (Url.toString url) )

                Browser.External url ->
                    ( stateBefore, Navigation.load url )

        UserInputSelectMemoryReadingSource selectedSource ->
            ( { stateBefore | selectedSource = selectedSource }, Cmd.none )

        UserInputSelectMemoryReadingFile Nothing ->
            ( stateBefore, File.Select.file [ "application/json" ] (Just >> UserInputSelectMemoryReadingFile) )

        UserInputSelectMemoryReadingFile (Just file) ->
            ( stateBefore, Task.perform ReadMemoryReadingFile (File.toString file) )

        ReadMemoryReadingFile partialPythonJson ->
            let
                memoryReading =
                    { partialPythonJson = partialPythonJson
                    , parseResult = partialPythonJson |> parseMemoryReadingFromPartialPythonJson
                    }
            in
            ( { stateBefore | readFromFileResult = Just memoryReading }, Cmd.none )

        UserInputSetTreeViewNodeIsExpanded treeViewNode isExpanded ->
            let
                expandedNodes =
                    if isExpanded then
                        treeViewNode :: stateBefore.treeView.expandedNodes

                    else
                        stateBefore.treeView.expandedNodes |> List.filter ((/=) treeViewNode)
            in
            ( { stateBefore | treeView = { expandedNodes = expandedNodes } }, Cmd.none )

        ContinueReadFromLiveProcess ->
            ( stateBefore, (stateBefore |> decideNextStepToReadFromLiveProcess).nextCmd )

        UserInputDownloadJsonFile jsonString ->
            ( stateBefore, File.Download.string "partialPython.json" "application/json" jsonString )


integrateBackendResponse : { request : InterfaceToFrontendClient.RequestFromClient, result : Result Http.Error ResponseFromServer } -> State -> State
integrateBackendResponse { request, result } stateBefore =
    case request of
        -- TODO: Consolidate unpack response common parts.
        InterfaceToFrontendClient.RunInVolatileHostRequest Sanderling.Sanderling.GetEveOnlineProcessesIds ->
            let
                getEveOnlineClientProcessesIdsResult =
                    result
                        |> Result.mapError describeHttpError
                        |> Result.andThen
                            (\response ->
                                case response of
                                    ReadLogResponse _ ->
                                        Err "Unexpected response"

                                    RunInVolatileHostResponse runInVolatileHostResponse ->
                                        case runInVolatileHostResponse of
                                            InterfaceToFrontendClient.SetupNotCompleteResponse ->
                                                Err "Volatile host setup not complete."

                                            InterfaceToFrontendClient.RunInVolatileHostCompleteResponse runInVolatileHostCompleteResponse ->
                                                case runInVolatileHostCompleteResponse.exceptionToString of
                                                    Just exception ->
                                                        Err ("Failed with exception: " ++ exception)

                                                    Nothing ->
                                                        runInVolatileHostCompleteResponse.returnValueToString
                                                            |> Maybe.withDefault ""
                                                            |> Sanderling.Sanderling.deserializeResponseFromVolatileHost
                                                            |> Result.mapError Json.Decode.errorToString
                                                            |> Result.andThen
                                                                (\responseFromVolatileHost ->
                                                                    case responseFromVolatileHost of
                                                                        Sanderling.Sanderling.EveOnlineProcessesIds processIds ->
                                                                            Ok (processIds |> Set.fromList)

                                                                        Sanderling.Sanderling.GetMemoryMeasurementResult _ ->
                                                                            Err "Unexpected response: GetMemoryMeasurementResult"
                                                                )
                            )

                readFromLiveProcessBefore =
                    stateBefore.readFromLiveProcess
            in
            { stateBefore
                | readFromLiveProcess =
                    { readFromLiveProcessBefore
                        | readEveOnlineClientProcessesIdsResult = Just getEveOnlineClientProcessesIdsResult
                    }
            }

        InterfaceToFrontendClient.RunInVolatileHostRequest (Sanderling.Sanderling.GetMemoryMeasurement _) ->
            let
                readMemoryResult =
                    result
                        |> Result.mapError describeHttpError
                        |> Result.andThen
                            (\response ->
                                case response of
                                    ReadLogResponse _ ->
                                        Err "Unexpected response"

                                    RunInVolatileHostResponse runInVolatileHostResponse ->
                                        case runInVolatileHostResponse of
                                            InterfaceToFrontendClient.SetupNotCompleteResponse ->
                                                Err "Volatile host setup not complete."

                                            InterfaceToFrontendClient.RunInVolatileHostCompleteResponse runInVolatileHostCompleteResponse ->
                                                case runInVolatileHostCompleteResponse.exceptionToString of
                                                    Just exception ->
                                                        Err ("Failed with exception: " ++ exception)

                                                    Nothing ->
                                                        runInVolatileHostCompleteResponse.returnValueToString
                                                            |> Maybe.withDefault ""
                                                            |> Sanderling.Sanderling.deserializeResponseFromVolatileHost
                                                            |> Result.mapError Json.Decode.errorToString
                                                            |> Result.andThen
                                                                (\responseFromVolatileHost ->
                                                                    case responseFromVolatileHost of
                                                                        Sanderling.Sanderling.EveOnlineProcessesIds _ ->
                                                                            Err "Unexpected response: EveOnlineProcessesIds"

                                                                        Sanderling.Sanderling.GetMemoryMeasurementResult getMemoryMeasurementResult ->
                                                                            case getMemoryMeasurementResult of
                                                                                Sanderling.Sanderling.ProcessNotFound ->
                                                                                    Err "Process not found"

                                                                                Sanderling.Sanderling.Completed memoryReadingCompleted ->
                                                                                    Ok memoryReadingCompleted
                                                                )
                            )
                        |> Result.andThen
                            (\memoryReadingCompleted ->
                                case memoryReadingCompleted.partialPythonJson of
                                    Nothing ->
                                        Err "Memory reading completed, but 'partialPythonJson' is null. Please configure EVE Online client and restart."

                                    Just partialPythonJson ->
                                        Ok
                                            { mainWindowId = memoryReadingCompleted.mainWindowId
                                            , memoryReading =
                                                { partialPythonJson = partialPythonJson
                                                , parseResult = partialPythonJson |> parseMemoryReadingFromPartialPythonJson
                                                }
                                            }
                            )

                readFromLiveProcessBefore =
                    stateBefore.readFromLiveProcess
            in
            { stateBefore | readFromLiveProcess = { readFromLiveProcessBefore | readMemoryResult = Just readMemoryResult } }

        _ ->
            stateBefore


decideNextStepToReadFromLiveProcess :
    State
    ->
        { describeState : String
        , lastMemoryReading : Maybe ReadFromLiveProcessCompleted
        , nextCmd : Cmd.Cmd Event
        }
decideNextStepToReadFromLiveProcess state =
    let
        requestGetProcessesIds =
            apiRequestCmd (InterfaceToFrontendClient.RunInVolatileHostRequest Sanderling.Sanderling.GetEveOnlineProcessesIds)
    in
    case state.readFromLiveProcess.readEveOnlineClientProcessesIdsResult of
        Nothing ->
            { describeState = "Did not yet search for the IDs of the EVE Online client processes."
            , lastMemoryReading = Nothing
            , nextCmd = requestGetProcessesIds
            }

        Just (Err error) ->
            { describeState = "Failed to get IDs of the EVE Online client processes: " ++ error
            , lastMemoryReading = Nothing
            , nextCmd = requestGetProcessesIds
            }

        Just (Ok eveOnlineClientProcessesIds) ->
            case eveOnlineClientProcessesIds |> Set.toList of
                [] ->
                    { describeState = "Looks like there is no EVE Online client process started. I continue looking in case one is started..."
                    , lastMemoryReading = Nothing
                    , nextCmd = requestGetProcessesIds
                    }

                firstEveOnlineClientProcessId :: _ ->
                    let
                        requestReadMemory =
                            apiRequestCmd
                                (InterfaceToFrontendClient.RunInVolatileHostRequest
                                    (Sanderling.Sanderling.GetMemoryMeasurement { processId = firstEveOnlineClientProcessId })
                                )

                        ( describeLastReadResult, lastMemoryReading ) =
                            case state.readFromLiveProcess.readMemoryResult of
                                Nothing ->
                                    ( "", Nothing )

                                Just (Err error) ->
                                    ( "The last attempt to read from the process memory failed: " ++ error, Nothing )

                                Just (Ok lastMemoryReadingCompleted) ->
                                    ( "The last attempt to read from the process memory was successful.", Just lastMemoryReadingCompleted )
                    in
                    { describeState =
                        "I try to read the memory from process "
                            ++ (firstEveOnlineClientProcessId |> String.fromInt)
                            ++ ". "
                            ++ describeLastReadResult
                    , nextCmd = requestReadMemory
                    , lastMemoryReading = lastMemoryReading
                    }


view : State -> Browser.Document Event
view state =
    let
        sourceSpecificHtml =
            case state.selectedSource of
                FromFile ->
                    viewSourceFromFile state

                FromLiveProcess ->
                    viewSourceFromLiveProcess state

        selectedSourceText =
            case state.selectedSource of
                FromFile ->
                    "file"

                FromLiveProcess ->
                    "live process"

        body =
            [ globalStylesHtmlElement
            , [ "Select a source for the memory reading" |> Html.text ] |> Html.h2 []
            , selectSourceHtml state
            , verticalSpacerFromHeightInEm 1
            , [ ("Reading from " ++ selectedSourceText) |> Html.text ] |> Html.h2 []
            , sourceSpecificHtml
            ]
    in
    { title = "Alternate EVE Online UI", body = body }


viewSourceFromFile : State -> Html.Html Event
viewSourceFromFile state =
    let
        buttonLoadFromFileHtml =
            [ "Click here to load a memory reading from a JSON file" |> Html.text ]
                |> Html.button [ HE.onClick (UserInputSelectMemoryReadingFile Nothing) ]

        memoryReadingFromFileHtml =
            case state.readFromFileResult of
                Nothing ->
                    "No memory reading loaded" |> Html.text

                Just memoryReadingCompleted ->
                    case memoryReadingCompleted.parseResult of
                        Err error ->
                            ("Failed to decode memory reading loaded from file: " ++ (error |> Json.Decode.errorToString)) |> Html.text

                        Ok parseSuccess ->
                            [ "Successfully read the memory reading from the file." |> Html.text
                            , presentParsedMemoryReading parseSuccess state
                            ]
                                |> List.map (List.singleton >> Html.div [])
                                |> Html.div []
    in
    [ buttonLoadFromFileHtml
    , verticalSpacerFromHeightInEm 1
    , memoryReadingFromFileHtml
    ]
        |> Html.div []


viewSourceFromLiveProcess : State -> Html.Html Event
viewSourceFromLiveProcess state =
    let
        nextStep =
            decideNextStepToReadFromLiveProcess state

        memoryReadingHtml =
            case nextStep.lastMemoryReading of
                Nothing ->
                    "" |> Html.text

                Just parsedReadMemoryResult ->
                    let
                        downloadButton =
                            [ "Click here to download this memory measurement to a JSON file." |> Html.text ]
                                |> Html.button [ HE.onClick (UserInputDownloadJsonFile parsedReadMemoryResult.memoryReading.partialPythonJson) ]

                        parsedHtml =
                            case parsedReadMemoryResult.memoryReading.parseResult of
                                Err parseError ->
                                    ("Failed to parse this memory reading: " ++ (parseError |> Json.Decode.errorToString)) |> Html.text

                                Ok parseSuccess ->
                                    presentParsedMemoryReading parseSuccess state
                    in
                    [ "Successfully read from the memory of the live process." |> Html.text
                    , downloadButton
                    , verticalSpacerFromHeightInEm 1
                    , parsedHtml
                    ]
                        |> List.map (List.singleton >> Html.div [])
                        |> Html.div []
    in
    [ nextStep.describeState |> Html.text
    , verticalSpacerFromHeightInEm 1
    , memoryReadingHtml
    ]
        |> Html.div []


presentParsedMemoryReading : ParseMemoryReadingSuccess -> State -> Html.Html Event
presentParsedMemoryReading memoryReading state =
    [ "Below is an interactive tree view to explore this memory reading. You can expand and collapse individual nodes." |> Html.text
    , viewTreeMemoryReadingUITreeNode state.treeView memoryReading.uiTree
    , verticalSpacerFromHeightInEm 0.5
    , [ "Overview" |> Html.text ] |> Html.h3 []
    , displayReadOverviewWindowResult memoryReading.overviewWindow
    ]
        |> List.map (List.singleton >> Html.div [])
        |> Html.div []


displayReadOverviewWindowResult : MaybeVisible OverviewWindow -> Html.Html Event
displayReadOverviewWindowResult maybeOverviewWindow =
    case maybeOverviewWindow of
        CanNotSeeIt ->
            "Can not see the overview window" |> Html.text

        CanSee overviewWindow ->
            let
                columns =
                    overviewWindow.headers

                headersHtml =
                    columns
                        |> List.map (Html.text >> List.singleton >> Html.td [])
                        |> Html.tr []

                entriesHtml =
                    overviewWindow.entries
                        |> List.map
                            (\overviewEntry ->
                                columns
                                    |> List.map
                                        (\column ->
                                            [ overviewEntry.cellsContents
                                                |> Dict.get column
                                                |> Maybe.withDefault ""
                                                |> Html.text
                                            ]
                                                |> Html.td []
                                        )
                                    |> Html.tr []
                            )
            in
            headersHtml
                :: entriesHtml
                |> Html.table []


selectSourceHtml : State -> Html.Html Event
selectSourceHtml state =
    [ ( "From file", FromFile ), ( "From live game client process", FromLiveProcess ) ]
        |> List.map
            (\( offeredSourceLabel, offeredSource ) ->
                radioButtonHtml
                    offeredSourceLabel
                    (state.selectedSource == offeredSource)
                    (UserInputSelectMemoryReadingSource offeredSource)
            )
        |> Html.div []


radioButtonHtml : String -> Bool -> event -> Html.Html event
radioButtonHtml labelText isChecked msg =
    [ Html.input [ HA.type_ "radio", HA.name "font-size", HE.onClick msg, HA.checked isChecked ] []
    , Html.text labelText
    ]
        |> Html.label [ HA.style "padding" "20px" ]


viewTreeMemoryReadingUITreeNode : TreeViewState -> MemoryReadingUITreeNode -> Html.Html Event
viewTreeMemoryReadingUITreeNode viewState treeNode =
    let
        nodeIdentityInView =
            { pythonObjAddress = treeNode.pythonObjAddress }

        expandableHtml viewNode getCollapsedContentHtml getExpandedContentHtml =
            let
                ( contentHtml, offeredNewExpensionState ) =
                    if viewState.expandedNodes |> List.member viewNode then
                        ( getExpandedContentHtml (), False )

                    else
                        ( getCollapsedContentHtml (), True )

                buttonLabel =
                    if offeredNewExpensionState then
                        "Expand"

                    else
                        "Collapse"

                buttonHtml =
                    [ buttonLabel |> Html.text ]
                        |> Html.button
                            [ HE.onClick (UserInputSetTreeViewNodeIsExpanded viewNode offeredNewExpensionState)
                            ]
            in
            [ [ buttonHtml, contentHtml ]
                |> List.map (List.singleton >> Html.td [ HA.attribute "valign" "top" ])
                |> Html.tr []
            ]
                |> Html.table []

        popularPropertiesDescription =
            treeNode.pythonObjTypeName
                :: ([ "Name" ]
                        |> List.filterMap
                            (\popularProperty ->
                                treeNode.otherProperties |> List.filter (Tuple.first >> (==) popularProperty) |> List.head
                            )
                        |> List.map (Tuple.second >> Json.Encode.encode 0)
                   )
                |> List.map (String.Extra.ellipsis 20)

        commonSummaryText =
            ((countDescendantsInUITreeNode treeNode |> String.fromInt)
                ++ " descendants"
            )
                :: popularPropertiesDescription
                |> String.join ", "

        commonSummaryHtml =
            commonSummaryText |> Html.text
    in
    expandableHtml
        (ExpandableUITreeNode nodeIdentityInView)
        (always commonSummaryHtml)
        (\() ->
            let
                otherPropertiesHtml =
                    treeNode.otherProperties
                        |> List.map (Tuple.mapSecond (Json.Encode.encode 0 >> Html.text >> List.singleton >> Html.span []))

                childrenHtml =
                    case treeNode.children |> Maybe.withDefault [] of
                        [] ->
                            "No children" |> Html.text

                        children ->
                            expandableHtml
                                (ExpandableUITreeNodeChildren nodeIdentityInView)
                                (always ((children |> List.length |> String.fromInt) ++ " children" |> Html.text))
                                (\() -> children |> List.map unwrapMemoryReadingUITreeNodeChild |> List.map (viewTreeMemoryReadingUITreeNode viewState) |> Html.div [])

                allProperties =
                    ( "summary", commonSummaryHtml )
                        :: ( "pythonObjAddress", treeNode.pythonObjAddress |> String.fromInt |> Html.text )
                        :: ( "pythonObjTypeName", treeNode.pythonObjTypeName |> Html.text )
                        :: otherPropertiesHtml
                        ++ [ ( "children", childrenHtml ) ]

                allPropertiesHtml =
                    allProperties
                        |> List.map
                            (\( propertyName, propertyValueHtml ) ->
                                [ [ propertyName |> Html.text ] |> Html.span []
                                , propertyValueHtml
                                ]
                                    |> List.map (List.singleton >> Html.td [ HA.attribute "valign" "top" ])
                                    |> Html.tr []
                            )
            in
            allPropertiesHtml |> Html.table []
        )


parseMemoryReadingFromPartialPythonJson : String -> Result Json.Decode.Error ParseMemoryReadingSuccess
parseMemoryReadingFromPartialPythonJson =
    decodeMemoryReadingFromString
        >> Result.map
            (\uiTree ->
                { uiTree = uiTree
                , overviewWindow = parseOverviewWindowFromUiRoot uiTree
                }
            )


parseOverviewWindowFromUiRoot : MemoryReadingUITreeNode -> MaybeVisible OverviewWindow
parseOverviewWindowFromUiRoot uiTreeRoot =
    case uiTreeRoot |> getMostPopulousDescendantMatchingPredicate (.pythonObjTypeName >> (==) "OverView") of
        Nothing ->
            CanNotSeeIt

        Just overviewWindowNode ->
            CanSee (overviewWindowNode |> parseOverviewWindow)


parseOverviewWindow : MemoryReadingUITreeNode -> OverviewWindow
parseOverviewWindow overviewWindowNode =
    let
        ( tableHeaders, overviewEntries ) =
            case overviewWindowNode |> getMostPopulousDescendantMatchingPredicate (.pythonObjTypeName >> String.toLower >> String.contains "scroll") of
                Nothing ->
                    ( [], [] )

                Just scrollNode ->
                    let
                        -- TODO: Reduce risk of wrong link of entry contents to columns: Use the global/absolute offset instead of a local one.
                        headers =
                            case scrollNode |> getMostPopulousDescendantMatchingPredicate (.pythonObjTypeName >> String.toLower >> String.contains "headers") of
                                Nothing ->
                                    []

                                Just headersContainerNode ->
                                    headersContainerNode
                                        |> listDescendantsInUITreeNode
                                        |> List.filterMap
                                            (\headerContainerCandidate ->
                                                if (headerContainerCandidate.pythonObjTypeName |> String.toLower) /= "container" then
                                                    Nothing

                                                else
                                                    let
                                                        maybeText =
                                                            headerContainerCandidate.children
                                                                |> Maybe.withDefault []
                                                                |> List.map unwrapMemoryReadingUITreeNodeChild
                                                                |> List.filterMap getDisplayText
                                                                |> List.head

                                                        maybeOffset =
                                                            headerContainerCandidate
                                                                |> getHorizontalOffsetFromParentAndWidth
                                                                |> Maybe.map (\offsetAndWidth -> offsetAndWidth.offset + offsetAndWidth.width // 2)
                                                    in
                                                    case ( maybeText, maybeOffset ) of
                                                        ( Just text, Just offset ) ->
                                                            Just { text = text, offset = offset }

                                                        _ ->
                                                            Nothing
                                            )

                        headersFromLeftToRight =
                            headers |> List.sortBy .offset

                        entries =
                            overviewWindowNode
                                |> listDescendantsInUITreeNode
                                |> List.filter (.pythonObjTypeName >> (==) "OverviewScrollEntry")
                                |> List.filterMap
                                    (\overviewEntryNode ->
                                        if (overviewEntryNode |> countDescendantsInUITreeNode) < 1 then
                                            Nothing

                                        else
                                            let
                                                childrenWithOffset =
                                                    overviewEntryNode.children
                                                        |> Maybe.withDefault []
                                                        |> List.map unwrapMemoryReadingUITreeNodeChild
                                                        |> List.filterMap
                                                            (\child ->
                                                                child
                                                                    |> getHorizontalOffsetFromParentAndWidth
                                                                    |> Maybe.map (\offsetAndWidth -> { uiNode = child, offset = offsetAndWidth.offset + offsetAndWidth.width // 2 })
                                                            )

                                                cellsContents =
                                                    headersFromLeftToRight
                                                        |> List.map
                                                            (\header ->
                                                                let
                                                                    childrenWithOffsetNotCloserToAnotherHeader =
                                                                        childrenWithOffset
                                                                            |> List.filter
                                                                                (\childWithOffset ->
                                                                                    let
                                                                                        closestHeader =
                                                                                            headersFromLeftToRight
                                                                                                |> List.sortBy (\otherHeader -> abs (otherHeader.offset - childWithOffset.offset))
                                                                                                |> List.head
                                                                                    in
                                                                                    closestHeader == Just header
                                                                                )

                                                                    maybeClosestChild =
                                                                        childrenWithOffsetNotCloserToAnotherHeader
                                                                            |> List.sortBy (\childNode -> abs (childNode.offset - header.offset))
                                                                            |> List.head
                                                                            |> Maybe.map .uiNode

                                                                    cellText =
                                                                        maybeClosestChild
                                                                            |> Maybe.andThen
                                                                                (\closestChild ->
                                                                                    (closestChild :: (closestChild |> listDescendantsInUITreeNode))
                                                                                        |> List.filterMap getDisplayText
                                                                                        |> List.sortBy (String.length >> negate)
                                                                                        |> List.head
                                                                                )
                                                                            |> Maybe.withDefault ""
                                                                in
                                                                ( header.text, cellText )
                                                            )
                                                        |> Dict.fromList
                                            in
                                            Just
                                                { uiTreeNode = overviewEntryNode
                                                , cellsContents = cellsContents
                                                }
                                    )
                                |> List.sortBy (.uiTreeNode >> getVerticalOffsetFromParent >> Maybe.withDefault 9999)
                    in
                    ( headersFromLeftToRight |> List.map .text, entries )
    in
    { headers = tableHeaders, entries = overviewEntries }


getDisplayText : MemoryReadingUITreeNode -> Maybe String
getDisplayText uiElement =
    [ "SetText", "Text" ]
        |> List.filterMap
            (\displayTextPropertyName ->
                uiElement.otherProperties
                    |> Dict.fromList
                    |> Dict.get displayTextPropertyName
                    |> Maybe.andThen (Json.Decode.decodeValue Json.Decode.string >> Result.toMaybe)
            )
        |> List.sortBy (String.length >> negate)
        |> List.head


getHorizontalOffsetFromParentAndWidth : MemoryReadingUITreeNode -> Maybe { offset : Int, width : Int }
getHorizontalOffsetFromParentAndWidth uiElement =
    let
        roundedNumberFromPropertyName propertyName =
            uiElement.otherProperties
                |> List.filter (Tuple.first >> (==) propertyName)
                |> List.head
                |> Maybe.andThen (Tuple.second >> Json.Decode.decodeValue Json.Decode.float >> Result.toMaybe)
                |> Maybe.map round
    in
    case ( roundedNumberFromPropertyName "LaageInParentA", roundedNumberFromPropertyName "GrööseA" ) of
        ( Just offset, Just width ) ->
            Just { offset = offset, width = width }

        _ ->
            Nothing


getVerticalOffsetFromParent : MemoryReadingUITreeNode -> Maybe Int
getVerticalOffsetFromParent =
    .otherProperties
        >> List.filter (Tuple.first >> (==) "LaageInParentB")
        >> List.head
        >> Maybe.andThen (Tuple.second >> Json.Decode.decodeValue Json.Decode.float >> Result.toMaybe)
        >> Maybe.map round


getMostPopulousDescendantMatchingPredicate : (MemoryReadingUITreeNode -> Bool) -> MemoryReadingUITreeNode -> Maybe MemoryReadingUITreeNode
getMostPopulousDescendantMatchingPredicate predicate parent =
    listDescendantsInUITreeNode parent
        |> List.filter predicate
        |> List.sortBy countDescendantsInUITreeNode
        |> List.reverse
        |> List.head


unwrapMemoryReadingUITreeNodeChild : MemoryReadingUITreeNodeChild -> MemoryReadingUITreeNode
unwrapMemoryReadingUITreeNodeChild wrappedNode =
    case wrappedNode of
        MemoryReadingUITreeNodeChild unwrapped ->
            unwrapped


countDescendantsInUITreeNode : MemoryReadingUITreeNode -> Int
countDescendantsInUITreeNode parent =
    parent.children
        |> Maybe.withDefault []
        |> List.map unwrapMemoryReadingUITreeNodeChild
        |> List.map (countDescendantsInUITreeNode >> (+) 1)
        |> List.sum


listDescendantsInUITreeNode : MemoryReadingUITreeNode -> List MemoryReadingUITreeNode
listDescendantsInUITreeNode parent =
    parent.children
        |> Maybe.withDefault []
        |> List.map unwrapMemoryReadingUITreeNodeChild
        |> List.concatMap (\child -> child :: listDescendantsInUITreeNode child)


decodeMemoryReadingFromString : String -> Result Json.Decode.Error MemoryReadingUITreeNode
decodeMemoryReadingFromString =
    Json.Decode.decodeString memoryReadingUITreeNodeDecoder >> Result.map unwrapMemoryReadingUITreeNodeChild


memoryReadingUITreeNodeDecoder : Json.Decode.Decoder MemoryReadingUITreeNodeChild
memoryReadingUITreeNodeDecoder =
    Json.Decode.map5
        (\originalJson pythonObjAddress pythonObjTypeName children otherProperties ->
            { originalJson = originalJson, pythonObjAddress = pythonObjAddress, pythonObjTypeName = pythonObjTypeName, children = children, otherProperties = otherProperties } |> MemoryReadingUITreeNodeChild
        )
        Json.Decode.value
        (Json.Decode.field "PyObjAddress" Json.Decode.int)
        (decodeOptionalField "PyObjTypName" Json.Decode.string |> Json.Decode.map (Maybe.withDefault ""))
        (decodeOptionalField "ListChild" (Json.Decode.list (Json.Decode.lazy (\_ -> memoryReadingUITreeNodeDecoder))))
        (Json.Decode.keyValuePairs Json.Decode.value |> Json.Decode.map (List.filter (\( property, _ ) -> [ "PyObjAddress", "PyObjTypName", "ListChild" ] |> List.member property |> not)))


decodeOptionalField : String -> Json.Decode.Decoder a -> Json.Decode.Decoder (Maybe a)
decodeOptionalField fieldName decoder =
    let
        finishDecoding json =
            case Json.Decode.decodeValue (Json.Decode.field fieldName Json.Decode.value) json of
                Ok val ->
                    -- The field is present, so run the decoder on it.
                    Json.Decode.map Just (Json.Decode.field fieldName decoder)

                Err _ ->
                    -- The field was missing, which is fine!
                    Json.Decode.succeed Nothing
    in
    Json.Decode.value
        |> Json.Decode.andThen finishDecoding


globalStylesHtmlElement : Html.Html a
globalStylesHtmlElement =
    """
body {
font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
margin: 1em;
}
"""
        |> Html.text
        |> List.singleton
        |> Html.node "style" []


verticalSpacerFromHeightInEm : Float -> Html.Html a
verticalSpacerFromHeightInEm heightInEm =
    [] |> Html.div [ HA.style "height" ((heightInEm |> String.fromFloat) ++ "em") ]


describeHttpError : Http.Error -> String
describeHttpError httpError =
    case httpError of
        Http.BadUrl errorMessage ->
            "Bad Url: " ++ errorMessage

        Http.Timeout ->
            "Timeout"

        Http.NetworkError ->
            "Network Error"

        Http.BadStatus statusCode ->
            "BadStatus: " ++ (statusCode |> String.fromInt)

        Http.BadBody errorMessage ->
            "BadPayload: " ++ errorMessage
