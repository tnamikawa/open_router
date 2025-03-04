# frozen_string_literal: true

RSpec.describe OpenRouter do
  it "has a version number" do
    expect(OpenRouter::VERSION).not_to be nil
  end

  describe OpenRouter::Client do
    let(:client) do
      OpenRouter::Client.new(access_token: ENV["ACCESS_TOKEN"]) do |config|
        config.faraday do |f|
          f.response :logger, ::Logger.new($stdout), { headers: true, bodies: true, errors: true } do |logger|
            logger.filter(/(Bearer) (\S+)/, '\1[REDACTED]')
          end
        end
      end
    end

    describe "#initialize" do
      it "yields the configuration" do
        expect { |b| OpenRouter::Client.new(&b) }.to yield_with_args(OpenRouter.configuration)
      end
    end

    describe "#complete" do
      let(:messages) { [{ role: "user", content: "What is the meaning of life?" }] }
      let(:extras) { { max_tokens: 300 } }

      it "sends a POST request to the completions endpoint with the correct parameters" do
        # let the call execute
        expect(client).to receive(:post).with(
          "/chat/completions",
          {
            model: "google/gemini-pro-1.5",
            messages: messages,
            max_tokens: 300
          }
        ).and_call_original
        
        # 実際にcompleteメソッドを呼び出す
        client.complete(messages: messages, model: "google/gemini-pro-1.5", extras: extras)
      end

      context "with multimodal messages" do
        let(:test_image_path) { File.expand_path("../fixtures/ocr_sample512.jpg", __FILE__) }
        let(:multimodal_messages) do
          [
            {
              role: "user",
              content: [
                { type: "text", text: "この画像に含まれる文字を読み取ってください" },
                { type: "image_url", image_url: { url: test_image_path, detail: "high" } }
              ]
            }
          ]
        end

        it "formats multimodal messages correctly and outputs OCR result" do
          expect(client).to receive(:post).with(
            "/chat/completions",
            {
              model: "google/gemini-pro-1.5",
              messages: [
                {
                  role: "user",
                  content: [
                    { type: "text", text: "この画像に含まれる文字を読み取ってください" },
                    {
                      type: "image_url",
                      image_url: {
                        url: /^data:image\/jpeg;base64,/,
                        detail: "high"
                      }
                    }
                  ]
                }
              ]
            }
          ).and_return({
            "id" => "test-id",
            "choices" => [
              {
                "message" => {
                  "role" => "assistant",
                  "content" => "OCR結果: サンプルテキスト"
                }
              }
            ]
          })

          response = client.complete(messages: multimodal_messages, model: "google/gemini-pro-1.5")
          expect(response["choices"][0]["message"]["content"]).to eq("OCR結果: サンプルテキスト")
        end

        it "performs actual OCR on the image" do
          response = client.complete(messages: multimodal_messages, model: "google/gemini-pro-1.5")
          expect(response["choices"][0]["message"]["content"]).to be_present
        end

        it "raises an error for non-existent file" do
          non_existent_path = "/path/to/non/existent/image.jpg"
          messages = [
            {
              role: "user",
              content: [
                { type: "text", text: "この画像について説明してください" },
                { type: "image_url", image_url: { url: non_existent_path } }
              ]
            }
          ]

          expect {
            client.complete(messages: messages, model: "openai/gpt-4o")
          }.to raise_error(ArgumentError, "File not found: #{non_existent_path}")
        end

        it "raises an error for unsupported image format" do
          unsupported_path = File.expand_path("../fixtures/test.txt", __FILE__)
          File.write(unsupported_path, "test content")
          messages = [
            {
              role: "user",
              content: [
                { type: "text", text: "この画像について説明してください" },
                { type: "image_url", image_url: { url: unsupported_path } }
              ]
            }
          ]

          expect {
            client.complete(messages: messages, model: "openai/gpt-4o")
          }.to raise_error(ArgumentError, "Unsupported image format: .txt")

          File.delete(unsupported_path)
        end
      end
    end

    describe "#models" do
      it "sends a GET request to the models endpoint" do
        expect(client).to receive(:get).with("/models").and_return({ "data" => [] })
        client.models
      end

      it "returns the data from the response" do
        allow(client).to receive(:get).and_return({ "data" => [{ "id" => "model1" }, { "id" => "model2" }] })
        expect(client.models).to eq([{ "id" => "model1" }, { "id" => "model2" }])
      end
    end

    describe "#query_generation_stats" do
      let(:generation_id) { "generation_123" }

      it "sends a GET request to the generation endpoint with the generation ID" do
        expect(client).to receive(:get).with("/generation?id=#{generation_id}").and_return({ "data" => {} })
        client.query_generation_stats(generation_id)
      end

      it "returns the data from the response" do
        allow(client).to receive(:get).and_return({ "data" => { "tokens" => 100, "cost" => 0.01 } })
        expect(client.query_generation_stats(generation_id)).to eq({ "tokens" => 100, "cost" => 0.01 })
      end
    end
  end
end
