# frozen_string_literal: true

class AppPackageIntegration < ApplicationRecord
  belongs_to :app_package
  belongs_to :app

  after_create :handle_registration

  # possible names for api requirements, 
  # it also holds a credentials accessor in which can hold a hash
  store :settings, accessors: %i[
    api_key
    api_secret
    project_id
    report_id
    access_token
    access_token_secret
    user_id
    user_token
    credentials
    verify_token
  ], coder: JSON

  validate do
    app_package.definitions.each do |definition|
      key = definition[:name].to_sym
      next unless self.class.stored_attributes[:settings].include?(key)
      errors.add(key, "#{key} is required") if send(key).blank?
    end
  end

  def message_api_klass
    @message_api_klass ||= "MessageApis::#{app_package.name.capitalize}".constantize.new(
      config: self.settings.dup.merge( 
        self.app_package.credentials || {} 
      )
    ) rescue nil
  end

  def merged_credentials
  end

  def trigger(event)
    klass = message_api_klass
    klass.trigger(event) if klass.respond_to?(:trigger)
  end

  def handle_registration
    register_hook if message_api_klass and message_api_klass.respond_to?(:register_webhook)
    message_api_klass.after_install if message_api_klass.respond_to?(:after_install)
  end

  def register_hook
    klass = message_api_klass
    response = klass.register_webhook(app_package, self)
    klass.subscribe_to_events if klass.respond_to?(:subscribe_to_events)
    response
  end

  def get_webhooks
    klass = message_api_klass
    response = klass.get_webhooks
  end

  def delete_webhooks
    klass = message_api_klass
    response = klass.delete_webhooks
  end

  def create_hook_from_params(params)
    message_api_klass.create_hook_from_params(params, self)
  end

  def process_event(params)
    message_api_klass.enqueue_process_event(params, self)
  end

  def send_message(conversation, options)
    message_api_klass.send_message(conversation, options)
  end

  def oauth_authorize
    message_api_klass.oauth_authorize(self.app, self) if message_api_klass.respond_to?(:oauth_authorize)
  end

  def encoded_id
    URLcrypt.encode("#{app.key}+#{self.id}")
  end

  def self.decode(encoded)
    result = URLcrypt.decode(encoded).split("+")
    App.find_by(key: result.first).app_package_integrations.find(result.last)
  end

  def hook_url
    "#{ENV['HOST']}/api/v1/hooks/receiver/#{encoded_id}"
    #"#{ENV['HOST']}/api/v1/hooks/#{app.key}/#{app_package.name.downcase}/#{self.id}"
  end

  def oauth_url
    "#{ENV['HOST']}/api/v1/oauth/callback/#{encoded_id}"
  end

  def receive_oauth_code(params)
    klass = message_api_klass.receive_oauth_code(params, self)
  end

  def get_presenter_manager
    begin
      "MessageApis::#{self.app_package.name}::PresenterManager"&.constantize
    rescue 
      ExternalPresenterManager
    end
  end

  def presenter
    @presenter ||= get_presenter_manager
  end

  def external_package?
    presenter == ExternalPresenterManager
  end

  # used in display
  def call_hook(params)
    #@presenter.submit_hook(params)
    params.merge!({package: self}) if external_package?

    response = case params[:kind]
    when "initialize" then presenter.initialize_hook(params)
    when "configure" then presenter.configure_hook(params)
    when "submit" then presenter.submit_hook(params)
    when "frame" then presenter.sheet_hook(params)
    when "content" then presenter.content_hook(params) # not used
    else raise 'not hook'
    end

    response = response.with_indifferent_access

    package_schema = PluginSchemaValidator.new(response[:definitions])
    raise package_schema.as_json unless package_schema.valid?

    if response["kind"] == 'initialize'
      params[:ctx][:field] = nil
      params[:ctx][:values] = response["results"]
      response = presenter.initialize_hook(params)
      response.merge!(kind: 'initialize')
    end

    return response if response[:results].blank?

    if message_key = params.dig(:ctx, :message_key) and message_key.present?
      # TODO: maybe refactor this logic, move it to another place
      message = params.dig(:ctx, :app).conversation_parts.find_by(
        key: message_key
      )

      values = params[:ctx][:values]
      m = message.message
      blocks = m.blocks.merge("schema"=> response[:definitions])
      m.blocks = blocks
      m.save_replied(response[:results])
    end

    response
  end
  
end

class ExternalPresenterManager

  def self.post(url, data)
    # it's just for restrict fields on app, refactor this!
    data[:ctx][:app] = data.dig(:ctx, :app).as_json(only: [:key, :name])

    resp = Faraday.post(
      url, 
      data.to_json,
      "Content-Type" => "application/json"
    )
    JSON.parse(resp.body)
  end

  def self.initialize_hook(data)
    url = data[:package].app_package.initialize_url
    self.post(url, data)
  end

  def self.configure_hook(data)
    url = data[:package].app_package.configure_url
    self.post(url, data)
  end

  def self.submit_hook(data)
    url = data[:package].app_package.submit_url
    self.post(url, data)
  end

  def self.sheet_hook(data)
    url = data[:package].app_package.sheet_url
    self.post(url, data)
  end

  def self.content_hook(data)
    url = data[:package].app_package.content_url
    self.post(url, data)
  end
end
