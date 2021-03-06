#! /usr/bin/env ruby
#
#   metrics-eventstore-streamcount
#
# DESCRIPTION:
#    Counts the items in any given number of streams
# OUTPUT:
#   metric data
#
# PLATFORMS:
#   Linux, Windows
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: json
#
# NOTES:
#
# LICENSE:
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'json'
require 'date'
require 'ip-helper.rb'
require 'sensu-plugin/metric/cli'


class StreamCountMetrics < Sensu::Plugin::Metric::CLI::Graphite
  option :no_discover_via_dns,
         description: 'Whether to use DNS lookup to discover other cluster nodes. (Default: false)',
         boolean: true,
         short: '-v',
         long: '--no_discover_via_dns',
         default: false

  option :cluster_dns,
         description: 'DNS name from which other nodes can be discovered.',
         short: '-d',
         long: '--cluster_dns cluster_dns',
         default: 'localhost'

  option :address,
         description: 'If no_discover_via_dns is set then this address will be used. (Default localhost)',
         short: '-a',
         long: '--address address',
         default: 'localhost'

  option :port,
         description: 'What port to use. (Default 2114)',
         short: '-p',
         long: '--port port',
         default: '2114'

  option :metric_path,
         description: 'What to prepend to output metrics (Default "<hostname>.eventstore")',
         short: '-m',
         long: '--metric_path metric_path',
         default: "#{Socket.gethostname}.eventstore"

  option :eventstore_identifier,
         description: 'An optional identifier to tag the data in graphite with a specific eventstore instance (Default nil, meaning no additional tag at all)',
         long: '--eventstore_identifier eventstore_identifier',
         default: nil

  option :json_config,
         description: 'Config name',
         short: '-j jsonconfig',
         long: '--json_config jsonconfig',
         required: false,
         default: 'metrics_eventstore_streamcount'

  option :streams,
         description: 'Streams to count, separated by commas (if not specified uses config file)',
         short: '-s streams',
         long: '--streams streams',
         default: nil

  option :username,
         description: 'Username of the user to access eventstore as (Default "admin")',
         long: '--username username',
         default: 'admin'

  option :password,
         description: 'If password is specified the username and password will be used to access eventstore',
         long: '--password password',
         default: nil

  def run
    no_discover_via_dns = config[:no_discover_via_dns]
    address = config[:address]
    port = config[:port]

    eventstore_identifier = config[:eventstore_identifier].nil? ? '' : ( '.' + config[:eventstore_identifier] )
    @prefix = config[:metric_path] + eventstore_identifier + '.streams.'

    @username = config[:username]
    @password = config[:password]

    if config[:streams].nil?
      streams = settings[config[:json_config]]['streams']
    else
      streams = config[:streams].split(',')
    end

    unless no_discover_via_dns
      cluster_dns = config[:cluster_dns]

      helper = IpHelper.new
      address = helper.get_local_ip_that_also_on_cluster cluster_dns

      critical address unless helper.is_valid_v4_ip address

      expected_nodes = helper.get_ips_in_cluster cluster_dns
    end

    streams.each do |stream|
      count_stream(address, port, stream)
    end

    ok
  end

  def count_stream(address, port, stream)
    begin
      if @password.nil?
        json_data = open("http://#{address}:#{port}/streams/#{stream}",
                         'Accept'=>'application/json') { |f| JSON.parse f.read }
      else
        json_data = open("http://#{address}:#{port}/streams/#{stream}",
                         'Accept'=>'application/json',
                         http_basic_authentication:[@username,@password]) { |f| JSON.parse f.read }
      end

      # read the event number from the eTag
      # not sure how stable this is
      # an alternative method would be to read streams/#{stream}/head/backward/1 and inspect next/previous
      #
      # we do this rather than inspect event titles because event titles wouldn't be informative in the
      # case of $ce-* and $et-* streams
      etag_string, _ = json_data['eTag'].split ';', 2
      etag_count = etag_string.to_i + 1

    rescue OpenURI::HTTPError => e
      if e.io.status[0] == '404'
        etag_count = '0'
      else
        raise
      end
    end

    output ( @prefix + stream + '.count' ), etag_count, Time.now.to_i
  end

end
