module ApiSpec (apiSpec) where

import qualified Data.Text as T
import qualified Data.Vector as V
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import OpenAI.Client
import System.Environment (getEnv)
import Test.Hspec

makeClient :: IO OpenAIClient
makeClient =
  do
    manager <- newManager tlsManagerSettings
    apiKey <- T.pack <$> getEnv "OPENAI_KEY"
    pure (makeOpenAIClient apiKey manager 2)

forceSuccess :: (MonadFail m, Show a) => m (Either a b) -> m b
forceSuccess req =
  req >>= \res ->
    case res of
      Left err -> fail (show err)
      Right ok -> pure ok

apiSpec :: Spec
apiSpec = do
  describe "2022 core api" apiTests2022
  describe "March 2023 core API" apiTests2023


---------------------------------
------- 2023 API tests ----------
---------------------------------

apiTests2023 :: SpecWith ()
apiTests2023 =
  beforeAll makeClient $ do
    describe "models api" $ do
      it "list models" $ \cli -> do
        res <- forceSuccess $ listModels cli
        (V.length (olData res) > 5) `shouldBe` True
        let model = V.head (olData res)
        mOwnedBy model `shouldBe` "openai"

      it "retrieve model" $ \cli -> do
        model <- forceSuccess $ getModel cli (ModelId "text-davinci-003")
        mOwnedBy model `shouldBe` "openai-internal"

    describe "completions api" $ do
      it "create completion" $ \cli -> do
        let completion = (defaultCompletionCreate (ModelId "text-ada-001") "The opposite of up is")
                           {ccrMaxTokens = Just 1, ccrTemperature = Just 0.1, ccrN = Just 1}
        res <- forceSuccess $ completeText cli completion
        crChoices res `shouldNotBe` []
        cchText (head (crChoices res)) `shouldBe` " down"

    describe "chat api" $ do
      it "create chat completion" $ \cli -> do
        let completion = defaultChatCompletionRequest (ModelId "gpt-3.5-turbo")
                                                      [ChatMessage {chmRole="user",
                                                                    chmContent="What is the opposite of up? Answer in one word."
                                                                    }]
        res <- forceSuccess $ completeChat cli completion
        chrChoices res `shouldNotBe` []
        chmContent (chchMessage (head (chrChoices res))) `shouldBe` "Down."

    describe "edits api" $ do
      it "create edit" $ \cli -> do
        let edit = (defaultEditCreate (ModelId "text-davinci-edit-001") "Fox" "Pluralize the word")
                     {edcrN = Just 1}
        res <- forceSuccess $ createTextEdit cli edit
        edrChoices res `shouldNotBe` []
        edchText (head $ edrChoices res) `shouldBe` "Foxes\n"

    -- TODO (2023.03.22): Create tests for images, audio APIs

    describe "embeddings api" $ do
      it "create embeddings" $ \cli -> do
        let embedding = EmbeddingCreate {embcModel=ModelId "text-embedding-ada-002", embcInput="Hello",embcUser=Nothing}
        res <- forceSuccess $ createEmbedding cli embedding
        embrData res `shouldNotBe` []
        V.length (embdEmbedding (head $ embrData res)) `shouldBe` 1536


---------------------------------
------- 2022 API tests ----------
---------------------------------

apiTests2022 :: SpecWith ()
apiTests2022 =
  beforeAll makeClient $
    do
      describe "file api" $
        do
          -- TODO 2023.03.22: This test is broken on old commit. Did not investigate
          it "allows creating one" $ \cli ->
            do
              let file =
                    FileCreate
                      { fcPurpose = "search",
                        fcDocuments = [FhSearch $ SearchHunk "Test 1" Nothing, FhSearch $ SearchHunk "text 2" (Just "foo")]
                      }
              _ <- forceSuccess $ createFile cli file
              pure ()
      describe "answer api" $
        do
          -- TODO 2023.03.22: This test is broken on old commit. Did not investigate
          it "works" $ \cli ->
            do
              let file =
                    FileCreate
                      { fcPurpose = "search",
                        fcDocuments =
                          [ FhSearch $ SearchHunk "Cities in California: San Francisco, Los Angeles" (Just "cali"),
                            FhSearch $ SearchHunk "Tasty fruit: Apple, Orange" (Just "fruit"),
                            FhSearch $ SearchHunk "Cities in Germany: Freiburg, Berlin" (Just "germany")
                          ]
                      }
              res <- forceSuccess $ createFile cli file
              let searchReq =
                    AnswerReq
                      { arFile = Just (fId res),
                        arDocuments = Nothing,
                        arQuestion = "Where is San Francisco?",
                        arSearchModel = EngineId "babbage",
                        arModel = EngineId "davinci",
                        arExamplesContext = "Good programming languages: Haskell, PureScript",
                        arExamples = [["Is PHP a good programming language?", "No, sorry."]],
                        arReturnMetadata = True
                      }
              answerRes <- forceSuccess $ getAnswer cli searchReq
              T.unpack (head (arsAnswers answerRes)) `shouldContain` ("California" :: String)
              pure ()
      describe "embeddings" $ do
        it "computes embeddings" $ \cli -> do
          res <- forceSuccess $ engineCreateEmbedding cli (EngineId "babbage-similarity") (EngineEmbeddingCreate "This is nice")
          V.null (olData res) `shouldBe` False
          let embedding = V.head (olData res)
          V.length (eneEngineEmbedding embedding) `shouldBe` 2048
      describe "fine tuning" $ do
        it "allows creating fine-tuning" $ \cli -> do
          let file =
                FileCreate
                  { fcPurpose = "fine-tune",
                    fcDocuments =
                      [ FhFineTune $ FineTuneHunk "So sad. Label:" "sad",
                        FhFineTune $ FineTuneHunk "So happy. Label:" "happy"
                      ]
                  }
          createRes <- forceSuccess $ createFile cli file
          let ftc = defaultFineTuneCreate (fId createRes)
          res <- forceSuccess $ createFineTune cli ftc
          ftStatus res `shouldBe` "pending"
      describe "engines" $
        do
          it "lists engines" $ \cli ->
            do
              res <- forceSuccess $ listEngines cli
              V.null (olData res) `shouldBe` False
          it "retrieve engine" $ \cli ->
            do
              engineList <- forceSuccess $ listEngines cli
              let firstEngine = V.head (olData engineList)
              engine <- forceSuccess $ getEngine cli (eId firstEngine)
              engine `shouldBe` firstEngine
      describe "text completion" $
        do
          it "works (smoke test)" $ \cli ->
            do
              firstEngine <- V.head . olData <$> forceSuccess (listEngines cli)
              completionResults <-
                forceSuccess $
                  engineCompleteText cli (eId firstEngine) $
                    (defaultEngineTextCompletionCreate "Why is the house ")
                      { tccrMaxTokens = Just 2
                      }
              V.length (tcChoices completionResults) `shouldBe` 1
              T.length (tccText (V.head (tcChoices completionResults))) `shouldNotBe` 0
      describe "document search" $
        do
          -- TODO 2023.03.22: This test is broken on old commit. Did not investigate
          it "works (smoke test)" $ \cli ->
            do
              firstEngine <- V.head . olData <$> forceSuccess (listEngines cli)
              searchResults <-
                forceSuccess $
                  searchDocuments cli (eId firstEngine) $
                    SearchResultCreate
                      { sccrDocuments = Just $ V.fromList ["pool", "gym", "night club"],
                        sccrFile = Nothing,
                        sccrQuery = "swimmer",
                        sccrReturnMetadata = False
                      }
              V.length (olData searchResults) `shouldBe` 3
      describe "file based document search" $
        do
          -- TODO 2023.03.22: This test is broken on old commit. Did not investigate
          it "works" $ \cli ->
            do
              let file =
                    FileCreate
                      { fcPurpose = "search",
                        fcDocuments =
                          [ FhSearch $ SearchHunk "pool" (Just "pool"),
                            FhSearch $ SearchHunk "gym" (Just "gym"),
                            FhSearch $ SearchHunk "night club" (Just "nc")
                          ]
                      }
              createRes <- forceSuccess $ createFile cli file
              let searchReq =
                    SearchResultCreate
                      { sccrFile = Just (fId createRes),
                        sccrDocuments = Nothing,
                        sccrQuery = "pool",
                        sccrReturnMetadata = True
                      }
              searchRes <- forceSuccess $ searchDocuments cli (EngineId "ada") searchReq
              let res = V.head (olData searchRes)
              srDocument res `shouldBe` 0 -- pool
              srMetadata res `shouldBe` Just "pool"
              pure ()
