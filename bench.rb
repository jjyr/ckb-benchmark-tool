#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'securerandom'
require 'ckb'
require 'colorize'
require 'terminal-table'

ALWAYS_SUCCESS = "0x0000000000000000000000000000000000000000000000000000000000000001".freeze
BIT = 100_000_000
PER_OUTPUT_CAPACITY = 128 * BIT
CELLBASE_REWARD = BIT * 50000
DEFAULT_STAT_FILE = "tx_records"

class BlockTime
  attr_accessor :timestamp, :number

  def initialize(timestamp:, number:)
    @timestamp = timestamp / 1000
    @number = number
  end

  def <=>(other)
    self.timestamp <=> other.timestamp
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
    block_time = BlockTime.new(number: header[:number].to_i, timestamp: header[:timestamp].to_i)
    proposed_count = block[:proposals].select do |proposal_id|
      mark_proposed proposal_id, block_time
    end.count
    proposed_count += block[:uncles].map do |uncle|
      uncle[:proposals].select do |proposal_id|
        mark_proposed proposal_id, block_time
      end.count
    end.sum
    if proposed_count > 0
      puts "#{proposed_count} txs get proposed".colorize(:green)
    end
    committed_count = block[:transactions].select do |tx|
      mark_committed tx[:hash], block_time
    end.count
    if committed_count > 0
      puts "#{committed_count} txs get committed".colorize(:green)
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
      # puts "tx #{tx_hash} get proposed at #{block_time}".colorize(:green)
      true
    else
      false
    end
  end

  def mark_committed tx_hash, block_time
    if (tx_task = @proposed.delete tx_hash)
      tx_task.committed_at = block_time
      @committed[tx_hash] = tx_task
      # puts "tx #{tx_hash} get commited at #{block_time}".colorize(:green)
      true
    else
      false
    end
  end
end

def random_lock_id
  "0x" + SecureRandom.hex
end

def get_always_success_lock_hash(args: [])
  always_success_lock = {
    code_hash: ALWAYS_SUCCESS,
    args: args
  }
  CKB::Utils.json_script_to_type_hash(always_success_lock)
end

def get_always_success_cellbase(api, from:, cap:)
  lock_hash = get_always_success_lock_hash
  cells = []
  while cells.size * CELLBASE_REWARD < cap
    new_cells = api.get_cells_by_lock_hash(lock_hash, from.to_s, (from + 10).to_s).select {|c| c[:capacity].to_i == CELLBASE_REWARD }
    if new_cells.empty?
      puts "can't found enough cellbase #{cap}"
      exit 1
    end
    cells += new_cells
    from += 10
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
      since: "0",
    }
  end

  total_cap = cells.map{|c| c[:capacity].to_i}.sum
  per_output_cap = (total_cap / count).to_s
  outputs = count.times.map do |i|
    {
      capacity: per_output_cap,
      data: CKB::Utils.bin_to_hex("prepare_tx#{i}"),
      lock: {
        code_hash: ALWAYS_SUCCESS,
        args: [lock_id]
      }
    }
  end

  tx = CKB::Transaction.new(
    version: 0,
    deps: [],
    inputs: inputs,
    outputs: outputs,
    witnesses: [],
  )
  tx_hash = api.send_transaction(tx.to_h)
  TxTask.new(tx_hash: tx_hash, send_at: send_time)
end

def send_txs(apis, prepare_tx_hash, txs_count, lock_id: )
  txs = txs_count.times.map do |i|
    inputs = [
      {
        previous_output: {tx_hash: prepare_tx_hash, index: i},
        args: [],
        since: "0"
      }
    ]
    outputs = [
      {
        capacity: PER_OUTPUT_CAPACITY.to_s,
        data: CKB::Utils.bin_to_hex(""),
        lock: {
          code_hash: ALWAYS_SUCCESS,
          args: [lock_id]
        }
      }
    ]

    CKB::Transaction.new(
      version: 0,
      deps: [],
      inputs: inputs,
      outputs: outputs,
      witnesses: [],
    )
  end
  queue = Queue.new()
  txs.each{|tx| queue.push tx}
  # sending
  puts "start #{apis.size} threads.."
  tip = apis[0].get_tip_header
  threads = apis.each_with_index.map do |api, worker_id|
    Thread.new(worker_id, api, tip) do |worker_id, api, tip|
      tx_tasks = []
      count = 0
      while tx = (queue.pop(true) rescue nil)
        count += 1
        if count % 100 == 0
          new_tip = api.get_tip_header 
          if new_tip[:timestamp].to_i > tip[:timestamp].to_i
            tip = new_tip
          end
        end
        block_time = BlockTime.new(number: tip[:number].to_i, timestamp: tip[:timestamp].to_i)
        print ".".colorize(:green)
        begin
          tx_hash = api.send_transaction(tx.to_h)
          tx_tasks << TxTask.new(tx_hash: tx_hash, send_at: block_time)
        rescue StandardError => e
          p "worker #{worker_id}: #{e}".colorize(:red)
        end
      end
      tx_tasks
    end
  end
  tx_tasks = threads.map(&:value).reduce(&:+)
  puts "send all transactions #{tx_tasks.size}/#{txs.size}"
  tx_tasks
end

def calculate_row(times)
  avg = times.sum / times.size.to_f
  median = times[times.size / 2]
  f_range = 0...(times.size / 5)
  f_20  = times[f_range].sum / f_range.size.to_f
  s_range = -(times.size / 5)..-1
  s_20  = times[s_range].sum / s_range.size.to_f
  [avg, median, f_20, s_20]
end

def statistics(tx_tasks)
  puts "Total: #{tx_tasks.size}"
  first_send = tx_tasks.sort_by(&:send_at).first
  last_committed = tx_tasks.sort_by(&:committed_at).last
  puts "Total TPS: #{tx_tasks.size / (last_committed.committed_at.timestamp - first_send.send_at.timestamp)}"
  # proposals
  head = ['type', 'avg', 'median', 'fastest 20%', 'slowest 20%', 'tps']
  rows = []
  propo_times = tx_tasks.map{|t| t.proposed_at.timestamp}.sort
  last_proposed = tx_tasks.sort_by(&:proposed_at).last
  propo_tps = propo_times.size / (last_proposed.proposed_at.timestamp - first_send.send_at.timestamp)
  rows << ['Proposed at', *calculate_row(propo_times).map{|t| t.infinite? ? t : Time.at(t.to_i)}, propo_tps]
  commit_times = tx_tasks.map{|t| t.committed_at.timestamp}.sort
  commit_tps = tx_tasks.size / (last_committed.committed_at.timestamp - first_send.send_at.timestamp)
  rows << ['Committed at', *calculate_row(commit_times).map{|t| t.infinite? ? t : Time.at(t.to_i)}, commit_tps]
  relative_times = tx_tasks.map{|t| t.proposed_at.timestamp - t.send_at.timestamp}.sort
  rows << ['Per tx proposed', *calculate_row(relative_times), propo_tps]
  relative_times = tx_tasks.map{|t| t.committed_at.timestamp - t.send_at.timestamp}.sort
  rows << ['Per tx committed', *calculate_row(relative_times), commit_tps]
  table = Terminal::Table.new :headings => head, :rows => rows
  puts table
end

def run(apis, from, txs_count)
  api = apis[0]
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
  tx_tasks = send_txs(apis, tx_task.tx_hash, txs_count, lock_id: lock_id)
  tx_tasks.each do |task|
    watch_pool.add task.tx_hash, task
  end
  puts "wait all txs get confirmed ...".colorize(:yellow)
  watch_pool.wait_all
  puts "complete, saving to ./#{DEFAULT_STAT_FILE} ...".colorize(:yellow)
  Marshal.dump(tx_tasks, open(DEFAULT_STAT_FILE, "w+"))
end

if __FILE__ == $0
  command = ARGV[0]
  if command == "run"
    from, txs_count = ARGV[1].to_i, ARGV[2].to_i
    api_url = ENV['API_URL'] || CKB::API::DEFAULT_URL
    apis = api_url.split("|").map {|url| CKB::API.new(host: url)}
    run(apis, from, txs_count)
  elsif command == "stat"
    stat_file = ARGV[1] || DEFAULT_STAT_FILE
    puts "statistics #{stat_file}..."
    tx_tasks = Marshal.load(open(stat_file, "r"))
    p tx_tasks.sort_by{|tx| tx.committed_at.timestamp - tx.proposed_at.timestamp}[-1]
    statistics(tx_tasks)
  else
    puts "unknown command #{command}"
    puts "try run benchmark: bench.rb run <block height> <count of tx>"
    puts "example: bench.rb run 23005 20"
    puts "try run stat: bench.rb stat <file>"
  end
end
