# frozen_string_literal: true

require "active_support/core_ext/object/blank"
require "active_support/core_ext/hash/indifferent_access"

require_relative "http"

module OpenRouter
  class ServerError < StandardError; end

  class Client
    include OpenRouter::HTTP

    # Initializes the client with optional configurations.
    def initialize(access_token: nil, request_timeout: nil, uri_base: nil, extra_headers: {})
      OpenRouter.configuration.access_token = access_token if access_token
      OpenRouter.configuration.request_timeout = request_timeout if request_timeout
      OpenRouter.configuration.uri_base = uri_base if uri_base
      OpenRouter.configuration.extra_headers = extra_headers if extra_headers.any?
      yield(OpenRouter.configuration) if block_given?
    end

    # 画像コンテンツを処理するプライベートメソッド
    # @param content [Hash] 画像コンテンツを含むハッシュ
    # @return [Hash] 処理された画像コンテンツ
    private def process_image_content(content)
      # image_urlフィールドがない場合はそのまま返す
      return content unless content[:image_url]

      # URLが既にBase64エンコードされている場合
      if content[:image_url][:url].to_s.start_with?("data:image/")
        return {
          type: "image_url",
          image_url: {
            url: content[:image_url][:url],
            detail: content[:image_url][:detail] || "auto"
          }
        }
      end

      # ローカルファイルの場合
      file_path = content[:image_url][:url]
      unless File.exist?(file_path)
        raise ArgumentError, "File not found: #{file_path}"
      end

      # 拡張子の取得
      ext = File.extname(file_path).downcase

      # サポートされている画像形式かチェック
      unless [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".tif", ".svg"].include?(ext)
        raise ArgumentError, "Unsupported image format: #{ext}"
      end

      # MIMEタイプの判定
      mime_type = case ext
                 when ".jpg", ".jpeg" then "image/jpeg"
                 when ".png" then "image/png"
                 when ".gif" then "image/gif"
                 when ".webp" then "image/webp"
                 when ".bmp" then "image/bmp"
                 when ".tiff", ".tif" then "image/tiff"
                 when ".svg" then "image/svg+xml"
                 else
                   # ここには到達しないはずだが、念のため
                   "image/#{ext[1..]}"
                 end

      # ファイルの読み込みとBase64エンコード
      begin
        base64_data = Base64.strict_encode64(File.binread(file_path))
        {
          type: "image_url",
          image_url: {
            url: "data:#{mime_type};base64,#{base64_data}",
            detail: content[:image_url][:detail] || "auto"
          }
        }
      rescue => e
        raise ArgumentError, "Failed to read or encode file: #{file_path} (#{e.message})"
      end
    end

    # Performs a chat completion request to the OpenRouter API.
    # @param messages [Array<Hash>] Array of message hashes with role and content, like [{role: "user", content: "What is the meaning of life?"}]
    # @param model [String|Array] Model identifier, or array of model identifiers if you want to fallback to the next model in case of failure
    # @param providers [Array<String>] Optional array of provider identifiers, ordered by priority
    # @param transforms [Array<String>] Optional array of strings that tell OpenRouter to apply a series of transformations to the prompt before sending it to the model. Transformations are applied in-order
    # @param extras [Hash] Optional hash of model-specific parameters to send to the OpenRouter API
    # @param stream [Proc, nil] Optional callable object for streaming
    # @return [Hash] The completion response.
    def complete(params)
      messages = params[:messages]
      model = params[:model]
      providers = params[:providers] || []
      transforms = params[:transforms] || []
      extras = params[:extras] || {}
      stream = params[:stream]

      # マルチモーダルメッセージの処理
      messages = messages.map do |message|
        # contentが配列でない場合はそのまま返す
        next message unless message[:content].is_a?(Array)

        # roleとnameを保持
        processed_message = { role: message[:role] }
        processed_message[:name] = message[:name] if message[:name]

        # contentの処理
        processed_message[:content] = message[:content].map do |content|
          case content[:type]
          when "image_url"
            process_image_content(content)
          when "text"
            # テキストコンテンツはそのまま返す
            content
          else
            # 未知のコンテンツタイプはそのまま返す
            content
          end
        end

        processed_message
      end

      parameters = { messages: messages }
      if model.is_a?(String)
        parameters[:model] = model
      elsif model.is_a?(Array)
        parameters[:models] = model
        parameters[:route] = "fallback"
      end
      parameters[:provider] = { provider: { order: providers } } if providers.any?
      parameters[:transforms] = transforms if transforms.any?
      parameters[:stream] = stream if stream
      parameters.merge!(extras)

      # パスは/api/v1/プレフィックスなしで指定（http.rbのuriメソッドで追加される）
      path = "/chat/completions"

      post(path, parameters).tap do |response|
        raise ServerError, response.dig("error", "message") if response.presence&.dig("error", "message").present?
        raise ServerError, "Empty response from OpenRouter. Might be worth retrying once or twice." if stream.blank? && response.blank?

        return response.with_indifferent_access if response.is_a?(Hash)
      end
    end

    # Fetches the list of available models from the OpenRouter API.
    # @return [Array<Hash>] The list of models.
    def models
      get("/models")["data"]
    end

    # Queries the generation stats for a given id.
    # @param generation_id [String] The generation id returned from a previous request.
    # @return [Hash] The stats including token counts and cost.
    def query_generation_stats(generation_id)
      response = get("/generation?id=#{generation_id}")
      response["data"]
    end
  end
end
