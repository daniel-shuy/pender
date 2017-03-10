require 'timeout'
require 'pender_exceptions'
require 'cc_deville'

module Api
  module V1
    class MediasController < Api::V1::BaseApiController
      include MediasDoc
      include MediasHelper

      skip_before_filter :authenticate_from_token!, if: proc { request.format.html? || request.format.js? || request.format.oembed? }
      after_action :allow_iframe, only: :index

      def index
        @url = params[:url]
        (render_parameters_missing and return) if @url.blank?
        
        @refresh = params[:refresh] == '1'
        @id = Digest::MD5.hexdigest(@url)
        
        render_timeout do
          (render_url_invalid and return) unless valid_url?
          @media = Media.new(url: @url, request: request)
        end and return
        
        respond_to do |format|
          list_formats.each do |f|
            format.send(f) { send("render_as_#{f}") }
          end
        end
      end

      def list_formats
        %w(html js json oembed)
      end

      private

      def allow_iframe
        response.headers.except! 'X-Frame-Options'
      end

      def render_as_json
        @request = request
        begin
          render_timeout { render_success('media', @media.as_json({ force: @refresh }).merge({ embed_tag: embed_url })) and return }
        rescue Pender::ApiLimitReached => e
          render_error e.reset_in, 'API_LIMIT_REACHED', 429
        rescue StandardError => e
          render_not_parseable(@media.data.merge(error: { message: e.message, code: 'UNKNOWN' }))
        end
      end

      def render_timeout
        timeout = CONFIG['timeout'] || 20
        key = Digest::MD5.hexdigest(@url)
        data = Rails.cache.read(key)
        
        if data.nil? || @refresh
          begin
            Timeout::timeout(timeout) { yield }
          rescue Timeout::Error
            data = @media.nil? ? Media.minimal_data(OpenStruct.new(url: @url)) : @media.data
            Rails.cache.write(key, data)
          end
        end
        
        if data.nil?
          return false
        else
          render_not_parseable(data.merge(error: { message: 'Timeout', code: 'TIMEOUT' })) and return true
        end
      end

      def render_as_html
        begin
          if @refresh || !File.exist?(cache_path)
            save_cache
          end
          render text: File.read(cache_path), status: 200
        rescue
          render html: 'Could not parse this media'
        end
      end

      def render_as_js
        @caller = request.original_url.gsub(/#.*/, '')
        render template: 'medias/index'
      end

      def render_as_oembed
        json = @media.as_oembed(request.original_url, params[:maxwidth], params[:maxheight], { force: @refresh })
        render json: json, status: 200
      end

      def save_cache
        av = ActionView::Base.new(Rails.root.join('app', 'views'))
        template = locals = nil
        data = @media.as_json({ force: @refresh })

        if !data['html'].blank?
          locals = { html: data['html'].html_safe }
          template = 'custom'
        else
          locals = { data: data }
          template = 'index'
        end

        av.assign(locals.merge({ request: request, id: @id, media: @media }))
        ActionView::Base.send :include, MediasHelper
        content = av.render(template: "medias/#{template}.html.erb", layout: 'layouts/application.html.erb')
        File.atomic_write(cache_path) { |file| file.write(content) }
        clear_upstream_cache if @refresh
      end

      def cache_path
        name = Digest::MD5.hexdigest(@url)
        dir = File.join('public', 'cache', Rails.env)
        FileUtils.mkdir_p(dir) unless File.exist?(dir)
        File.join(dir, "#{name}.html")
      end

      def valid_url?
        Media.validate_url(@url)
      end

      def clear_upstream_cache
        if CONFIG['cc_deville_host'].present? && CONFIG['cc_deville_token'].present?
          url = request.original_url
          cc = CcDeville.new(CONFIG['cc_deville_host'], CONFIG['cc_deville_token'], CONFIG['cc_deville_httpauth'])
          cc.clear_cache(url)
          url_no_refresh = url.gsub(/&?refresh=1&?/, '')
          cc.clear_cache(url_no_refresh) if url != url_no_refresh
        end
      end
    end
  end
end
