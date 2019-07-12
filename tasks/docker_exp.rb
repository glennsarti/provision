#!/usr/bin/env ruby
require 'json'
require 'yaml'
require 'puppet_litmus'
require_relative '../lib/task_helper'

# TODO: detect what shell to use
@shell_command = 'bash -lc'

def docker_version
  return @docker_info unless @docker_info.nil?
  result = run_local_command('docker version --format "{{json .}}"').strip

  begin
    @docker_info = JSON.parse(result)
  rescue StandardError => e
    raise "Unable to determine Docker version information: #{result}"
  end
  raise "Missing Docker server information from #{result}" if @docker_info['Server'].nil?
  @docker_info
end

def windows_docker_server?
  docker_version['Server']['Os'].downcase == 'windows'
end

def windows_platform?(platform)
  platform =~ /windows/
end

def provision(docker_platform, inventory_location)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  inventory_hash = get_inventory_hash(inventory_full_path)

  deb_family_systemd_volume = if (docker_platform =~ %r{debian|ubuntu}) && (docker_platform !~ %r{debian8|ubuntu14})
                                '--volume /sys/fs/cgroup:/sys/fs/cgroup:ro'
                              else
                                ''
                              end

  # privileged is supported on Windows based Docker daemons
  priv_mode = windows_docker_server? ? '' : '--privileged '
  creation_command = "docker run -d -it #{deb_family_systemd_volume} #{priv_mode} #{docker_platform}"
  container_id = run_local_command(creation_command).strip
  node = { 'name' => container_id,
           'config' => { 'transport' => 'docker', 'docker' => { 'shell-command' => @shell_command } },
           'facts' => { 'provisioner' => 'docker_exp', 'container_id' => container_id, 'platform' => docker_platform } }
  group_name = 'docker_nodes'
  add_node_to_group(inventory_hash, node, group_name)
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok', node_name: container_id }
end

def tear_down(node_name, inventory_location)
  include PuppetLitmus::InventoryManipulation
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  raise "Unable to find '#{inventory_full_path}'" unless File.file?(inventory_full_path)
  inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
  node_facts = facts_from_node(inventory_hash, node_name)
  remove_docker = "docker rm -f #{node_facts['container_id']}"
  run_local_command(remove_docker)
  remove_node(inventory_hash, node_name)
  puts "Removed #{node_name}"
  File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  { status: 'ok' }
end

#provision('mcr.microsoft.com/windows/servercore:1903', 'C:\Source\puppet-strings')

params = JSON.parse(STDIN.read)
platform = params['platform']
action = params['action']
node_name = params['node_name']
inventory_location = params['inventory']
raise 'specify a node_name if tearing down' if action == 'tear_down' && node_name.nil?
raise 'specify a platform if provisioning' if action == 'provision' && platform.nil?

begin
  result = provision(platform, inventory_location) if action == 'provision'
  result = tear_down(node_name, inventory_location) if action == 'tear_down'
  puts result.to_json
  exit 0
rescue => e
  puts({ _error: { kind: 'facter_task/failure', msg: e.message } }.to_json)
  exit 1
end
