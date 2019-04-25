#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'securerandom'
require 'colorize'
require 'ckb'

ALWAYS_SUCCESS = "0x0000000000000000000000000000000000000000000000000000000000000001".freeze
PER_OUTPUT_CAPACITY = 128

class BlockTime
  attr_accessor :timestamp, :number

  def initialize(timestamp:, number:)
    @timestamp = timestamp
    @number = number
  end

  def to_s
    "block #{number} #{timestamp}"
  end
end

class TxTask
  attr_accessor :tx_hash, :send_at, :proposed_at, :committed_at

  def initialize(tx_hash:, send_at:, proposed_at: nil, committed_at: nil)
    @tx_hash = tx_hash
    @send_at = send_at
    @proposed_at = proposed_at
    @committed_at = committed_at
  end

  def to_s
    "task #{tx_hash} send_at #{send_at} proposed_at #{proposed_at} committed_at #{committed_at}"
  end
end

class WatchPool
  def initialize(api, height)
    @api = api
    @height = height
    @initial = {}
    @short_id = {}
    @proposed = {}
    @committed = {}
  end

  def add(tx_hash, task)
    @initial[tx_hash] = task
    @short_id[tx_hash[0..21]] = tx_hash
  end

  def poll
    block_hash = @api.get_block_hash((@height + 1).to_s)
    puts "check block #{@height + 1} #{block_hash}"
    if block_hash.nil?
      return false
    end
    block = @api.get_block(block_hash)
    header = block[:header]
    block_time = BlockTime.new(number: header[:number], timestamp: header[:timestamp])
    block[:proposal_transactions].each do |proposal_id|
      mark_proposed proposal_id, block_time
    end
    block[:commit_transactions].each do |tx|
      mark_committed tx[:hash], block_time
    end
    @height += 1
    true
  end

  def wait(tx_hash)
    loop do
      sleep 3 unless poll
      return if @committed.include? tx_hash
    end
  end

  def wait_all
    loop do
      sleep 3 unless poll
      return if @initial.empty? && @proposed.empty?
    end
  end

  private

  def mark_proposed proposal_id, block_time
    if (tx_hash = @short_id.delete proposal_id)
      tx_task = @initial.delete(tx_hash)
      raise "fuck, should not happen" if tx_task.nil?
      tx_task.proposed_at = block_time
      @proposed[tx_hash] = tx_task
      puts "tx #{tx_hash} get proposed at #{block_time}".colorize(:green)
    end
  end

  def mark_committed tx_hash, block_time
    if (tx_task = @proposed.delete tx_hash)
      tx_task.committed_at = block_time
      @committed[tx_hash] = tx_task
      puts "tx #{tx_hash} get commited at #{block_time}".colorize(:green)
    end
  end
end

def random_lock_id
  "0x" + SecureRandom.hex
end

def get_always_success_lock_hash(args: [])
  always_success_lock = {
    binary_hash: ALWAYS_SUCCESS,
    args: args
  }
  CKB::Utils.json_script_to_type_hash(always_success_lock)
end

def get_always_success_cellbase(api, from:, cap:)
  lock_hash = get_always_success_lock_hash
  cells = []
  while cells.size * 50000 < cap
    new_cells = api.get_cells_by_lock_hash(lock_hash, from.to_s, (from + 100).to_s).select {|c| c[:capacity] == 50000 }
    if new_cells.empty?
      puts "can't found enough cellbase #{cap}"
      exit 1
    end
    cells += new_cells
    from += 100
  end
  cells
end

def prepare_cells(api, from, count, lock_id: )
  cells = get_always_success_cellbase(api, from: from, cap: count * PER_OUTPUT_CAPACITY)
  if cells.empty?
    puts "can't find cellbase in #{from}"
    exit 1
  end
  puts "found cellbases"
  # produce cells
  tip = api.get_tip_header
  send_time = BlockTime.new(number: tip[:number].to_i, timestamp: tip[:timestamp].to_i)

  inputs = cells.map do |cell|
    {
      previous_output: cell[:out_point],
      args: [],
      valid_since: "0",
    }
  end

  total_cap = cells.map{|c| c[:capacity]}.sum
  per_output_cap = (total_cap / count).to_s
  outputs = count.times.map do |i|
    {
      capacity: per_output_cap,
      data: CKB::Utils.bin_to_hex("prepare_tx#{i}"),
      lock: {
        binary_hash: ALWAYS_SUCCESS,
        args: [lock_id]
      }
    }
  end

  tx = CKB::Transaction.new(
    version: 0,
    deps: [api.system_script_out_point],
    inputs: inputs,
    outputs: outputs
  )
  tx_hash = api.send_transaction(tx.to_h)
  TxTask.new(tx_hash: tx_hash, send_at: send_time)
end

def send_txs(api, prepare_tx_hash, txs_count, lock_id: )
  txs = txs_count.times.map do |i|
    inputs = [
      {
        previous_output: {hash: prepare_tx_hash, index: i},
        args: [],
        valid_since: "0"
      }
    ]
    outputs = [
      {
        capacity: PER_OUTPUT_CAPACITY.to_s,
        data: CKB::Utils.bin_to_hex(""),
        lock: {
          binary_hash: ALWAYS_SUCCESS,
          args: [lock_id]
        }
      }
    ]

    CKB::Transaction.new(
      version: 0,
      deps: [api.system_script_out_point],
      inputs: inputs,
      outputs: outputs,
    )
  end
  tip = api.get_tip_header
  block_time = BlockTime.new(number: tip[:number].to_i, timestamp: tip[:timestamp].to_i)
  # sending
  tx_tasks = []
  txs.each_with_index do |tx, i|
    puts "sending tx #{i}/#{txs.size} ..."
    begin
      tx_hash = api.send_transaction(tx.to_h)
      tx_tasks << TxTask.new(tx_hash: tx_hash, send_at: block_time)
    rescue StandardError => e
      p e
    end
  end
  puts "send all transactions #{tx_tasks.size}/#{txs.size}"
  tx_tasks
end

def statistics(tx_tasks)
  puts "Total: #{tx_tasks.size}"
end

def run(api, from, txs_count)
  tip = api.get_tip_header
  watch_pool = WatchPool.new(api, tip[:number].to_i)
  lock_id = random_lock_id
  puts "generate random lock_id: #{lock_id}"
  puts "prepare #{txs_count} benchmark cells from height #{from}".colorize(:yellow)
  tx_task = prepare_cells(api, from, txs_count, lock_id: lock_id)
  watch_pool.add(tx_task.tx_hash, tx_task)
  puts "wait prepare tx get confirmed ...".colorize(:yellow)
  puts tx_task
  watch_pool.wait(tx_task.tx_hash)
  puts "start sending #{txs_count} txs...".colorize(:yellow)
  tx_tasks = send_txs(api, tx_task.tx_hash, txs_count, lock_id: lock_id)
  tx_tasks.each do |task|
    watch_pool.add task.tx_hash, task
  end
  puts "wait all txs get confirmed ...".colorize(:yellow)
  watch_pool.wait_all
  puts "complete, saving ...".colorize(:yellow)
  Marshal.dump(tx_tasks, open("tx_records", "w+"))
  puts "statistis ...".colorize(:yellow)
  statistics(tx_tasks)
end

if __FILE__ == $0
  api = CKB::API.new
  command, from, txs_count = ARGV[0], ARGV[1].to_i, ARGV[2].to_i
  if command == "run"
  run(api, from, txs_count)
  elsif command == "stat"
    puts "statistics..."
  else
    puts "unknown command #{command}"
    puts "try: bench.rb run <block height> <count of tx>"
    puts "example: bench.rb run 23005 20"
  end
end
