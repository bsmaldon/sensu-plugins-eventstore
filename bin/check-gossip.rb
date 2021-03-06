#! /usr/bin/env ruby
#
#   check-gossip
#
# DESCRIPTION:
#    Checks the event store gossip page, making sure everything is working as expected
# OUTPUT:
#   plain text, metric data, etc
#
# PLATFORMS:
#   Linux, Windows
#
# DEPENDENCIES:
#   gem: sensu-plugin
#   gem: nokogiri
#
# NOTES:
#
# LICENSE:
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'nokogiri'
require 'ip-helper.rb'
require 'sensu-plugin/check/cli'


class CheckGossip < Sensu::Plugin::Check::CLI
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

  option :gossip_address,
         description: 'If discover_via_dns is set to false then this address will be used for gossip. (Default localhost)',
         short: '-g',
         long: '--gossip_ip gossip_ip',
         default: 'localhost'

  option :gossip_port,
         description: 'What port to use when connecting to gossip. (Default 2113)',
         short: '-p',
         long: '--gossip_port gossip_port',
         default: '2113'

  option :expected_nodes,
         description: 'The total number of nodes we expect to be gossiping, including this one. (Default 4)',
         short: '-e',
         long: '--expected_nodes expected_nodes',
         proc: proc(&:to_i),
         default: 4

  option :epoch_threshold,
         description: 'The maximum allowable threshold before the epoch position is considered to be too far behind and trigger a critical alert. (-1 for no threshold) (Default 0, triggers on non-equal epoch position with master)',
         short: '-t',
         long: '--epoch_threshold epoch_threshold',
         proc: proc(&:to_i),
         default: 0

  def run
    no_discover_via_dns = config[:no_discover_via_dns]
    gossip_address = config[:gossip_address]
    gossip_port = config[:gossip_port]
    expected_nodes = config[:expected_nodes]
    epoch_threshold = config[:epoch_threshold]

    unless no_discover_via_dns
      cluster_dns = config[:cluster_dns]

      helper = IpHelper.new
      gossip_address = helper.get_local_ip_that_also_on_cluster cluster_dns

      critical gossip_address unless helper.is_valid_v4_ip gossip_address

      expected_nodes = helper.get_ips_in_cluster cluster_dns
    end

    check_node gossip_address, gossip_port, expected_nodes, epoch_threshold
  end

  def get_master_count(document)
    get_states(document).count { |state| state.content == 'Master' }
  end

  def get_members(document)
    document.xpath '//MemberInfoDto'
  end

  def get_is_alive_nodes(document)
    document.xpath '//IsAlive'
  end

  def get_states(document)
    document.xpath '//State'
  end

  def get_master_epoch(document)
    xml_nodes = document.xpath "/ClusterInfoDto/Members/MemberInfoDto[State='Master']/EpochPosition"
    # assume that one and only one node is master, this is being actively checked elsewhere so we would
    # already know about it if this weren't the case
    xml_nodes[0].content
  end

  def get_target_ip(document)
    xml_nodes = document.xpath "/ClusterInfoDto/ServerIp"
    xml_nodes[0].content
  end

  def get_target_epoch(document)
    target_ip = get_target_ip document
    # expect this to return one and only one node, if not then should fall over and die
    xml_nodes = document.xpath "/ClusterInfoDto/Members/MemberInfoDto[InternalHttpIp='#{target_ip}']/EpochPosition"

    if xml_nodes.count == 1
      xml_nodes[0].content
    else
      critical_malformed_gossip "number of nodes matching InternalHttpIp == #{xml_nodes.count}"
    end
  end

  def only_one_master?(document)
    get_master_count(document) == 1
  end

  def all_nodes_master_or_slave?(document)
    states = get_states document
    states.all? {|node| node.content == "Master" || node.content == "Slave"}
  end

  def node_count_is_correct?(document, expected_count)
    get_members(document).count == expected_count
  end

  def nodes_all_alive?(document)
    nodes = get_is_alive_nodes document
    nodes.all? { |node| node_is_alive? node }
  end

  def target_epoch_up_to_date?(document, epoch_threshold)
    get_master_epoch(document).to_i - get_target_epoch(document).to_i <= epoch_threshold
  end

  def critical_missing_nodes(xml_doc, expected_nodes)
    critical "Wrong number of nodes, was #{get_members(xml_doc).count} should be #{expected_nodes}"
  end
  def critical_dead_nodes(xml_doc, expected_nodes)
    critical "Only #{get_is_alive_nodes(xml_doc).count { |node| node_is_alive? node}} alive nodes, should be #{expected_nodes} alive"
  end
  def critical_master_count(xml_doc)
    critical "Wrong number of node masters, there should be 1 but there were #{get_master_count(xml_doc)} masters"
  end
  def critical_target_behind_master(xml_doc)
    critical "Target epoch [#{get_target_epoch(xml_doc)}] is behind master epoch [#{get_master_epoch(xml_doc)}]"
  end
  def critical_malformed_gossip(reason)
    critical "Malformed gossip file, because of: #{reason}"
  end
  def warn_nodes_not_ready(xml_doc)
    states = get_states xml_doc
    states = states.find { |node| node.content != "Master" and node.content != "Slave"}
    warn "nodes found with states: #{states} when expected Master or Slave."
    exit 1
  end

  def node_is_alive?(node)
    node.content == 'true'
  end

  def check_node(gossip_address, gossip_port, expected_nodes, epoch_threshold)
    puts "\nchecking gossip at #{gossip_address}:#{gossip_port}"

    begin
      connection_url = "http://#{gossip_address}:#{gossip_port}/gossip?format=xml"
      gossip = open(connection_url)
    rescue StandardError
      critical "Could not connect to #{connection_url} to check gossip, has event store fallen over on this node? "
    end

    xml_doc = Nokogiri::XML(gossip.readline)

    puts "Checking for #{expected_nodes} nodes"
    critical_missing_nodes xml_doc, expected_nodes unless node_count_is_correct? xml_doc, expected_nodes

    puts "Checking nodes for IsAlive state"
    critical_dead_nodes xml_doc, expected_nodes unless nodes_all_alive? xml_doc

    puts "Checking for exactly 1 master"
    critical_master_count xml_doc unless only_one_master? xml_doc

    puts "Checking node state"
    warn_nodes_not_ready xml_doc unless all_nodes_master_or_slave? xml_doc

    if epoch_threshold < 0
      puts "Skipping epoch position check"
    else
      puts "Checking that target epoch is not lagging too far behind master"
      critical_target_behind_master xml_doc unless target_epoch_up_to_date? xml_doc, epoch_threshold
    end

    ok "#{gossip_address} is gossiping with #{expected_nodes} nodes, all nodes are alive, exactly one master node was found, all other nodes are in the 'Slave' state, and all nodes are up to date."
  end
end
