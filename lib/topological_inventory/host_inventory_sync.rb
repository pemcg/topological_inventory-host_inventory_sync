require "concurrent"
require "json"
require "manageiq-messaging"
require 'rest_client'
require "topological_inventory-ingress_api-client"

module TopologicalInventory
  class HostInventorySync
    include Logging

    attr_reader :source, :sns_topic

    def initialize(topological_inventory_api, host_inventory_api, queue_host, queue_port)
      self.queue_host                = queue_host
      self.queue_port                = queue_port
      self.topological_inventory_api = topological_inventory_api
      self.host_inventory_api        = host_inventory_api
    end

    def run
      client = ManageIQ::Messaging::Client.open(default_messaging_opts.merge(:host => queue_host, :port => queue_port))

      queue_opts = {
        :service     => "platform.topological-inventory.persister-output",
        :persist_ref => "host_inventory_sync_worker"
      }

      # Can't use 'subscribe_messages' until https://github.com/ManageIQ/manageiq-messaging/issues/38 is fixed
      # client.subscribe_messages(queue_opts.merge(:max_bytes => 500000)) do |messages|
      begin
        client.subscribe_topic(queue_opts) do |message|
          process_message(message)
        end
      ensure
        client&.close
      end
    end

    private

    attr_accessor :log, :queue_host, :queue_port, :topological_inventory_api, :host_inventory_api

    def process_message(message)
      payload        = message.payload
      account_number = payload["external_tenant"]
      source         = payload["source"]
      x_rh_identity  = Base64.encode64({"identity" => {"account_number" => account_number}}.to_json)

      unless payload["external_tenant"]
        logger.error("Skipping payload because of missing :external_tenant. Payload: #{payload}")
        return
      end

      topological_inventory_vms = []

      get_topological_inventory_vms(payload, x_rh_identity).each do |host|
        # TODO(lsmola) filtering out if we don't have mac adress until source_ref becomes canonical fact
        mac_addresses = host.dig("extra", "network", "mac_addresses")
        next if mac_addresses.nil? || mac_addresses.empty?

        # Skip processing if we've already created this host in Host Based
        next if host["host_inventory_uuid"]

        data         = {:mac_addresses => mac_addresses, :account => account_number}
        created_host = JSON.parse(create_host_inventory_hosts(x_rh_identity, data).body)

        topological_inventory_vms << TopologicalInventoryIngressApiClient::Vm.new(
          :source_ref          => host["source_ref"],
          :host_inventory_uuid => created_host["id"],
        )
      end

      save_vms_to_topological_inventory(topological_inventory_vms, source)
    rescue => e
      logger.error(e.message)
      logger.error(e.backtrace.join("\n"))
    end

    def save_vms_to_topological_inventory(topological_inventory_vms, source)
      return if topological_inventory_vms.empty?

      # TODO(lsmola) if VM will have subcollections, this will need to send just partial data, otherwise all subcollections
      # would get deleted. Alternative is having another endpoint than :vms, for doing update only operation.
      ingress_api_client.save_inventory(
        :inventory => TopologicalInventoryIngressApiClient::Inventory.new(
          :schema      => TopologicalInventoryIngressApiClient::Schema.new(:name => "Default"),
          :source      => source,
          :collections => [
            TopologicalInventoryIngressApiClient::InventoryCollection.new(:name => :vms, :partial_data => topological_inventory_vms)
          ],
        )
      )
    end

    def ingress_api_client
      TopologicalInventoryIngressApiClient::DefaultApi.new
    end

    def create_host_inventory_hosts(x_rh_identity, data)
      RestClient::Request.execute(
        :method  => :post,
        :payload => data.to_json,
        :url     => "http://#{host_inventory_api}v1/hosts",
        :headers => {"Content-Type" => "application/json", "x-rh-identity" => x_rh_identity}
      )
    end

    def get_host_inventory_hosts(x_rh_identity)
      RestClient::Request.execute(
        :method  => :get,
        :url     => "http://#{host_inventory_api}v1/hosts",
        :headers => {"x-rh-identity" => x_rh_identity}
      )
    end

    def get_topological_inventory_vms(payload, x_rh_identity)
      vms         = payload.dig("payload", "vms") || {}
      changed_vms = (vms["updated"] || []).map { |x| x["id"] }
      created_vms = (vms["created"] || []).map { |x| x["id"] }
      deleted_vms = (vms["deleted"] || []).map { |x| x["id"] }

      # TODO(lsmola) replace with batch filtering once Topological Inventory implements that
      (changed_vms + created_vms + deleted_vms).map do |id|
        get_topological_inventory_vm(x_rh_identity, id)
      end.compact
    end

    def get_topological_inventory_vm(x_rh_identity, id)
      JSON.parse(
        RestClient::Request.execute(
          :method  => :get,
          :url     => "#{topological_inventory_api}/v0.1/vms/#{id}",
          :headers => {"x-rh-identity" => x_rh_identity}).body
      )
    rescue RestClient::NotFound
      logger.info("Vm #{id} was not found in Topological Inventory")
      nil
    end

    def default_messaging_opts
      {
        :protocol   => :Kafka,
        :client_ref => "persister-worker",
        :group_ref  => "persister-worker",
      }
    end
  end
end
