#! /usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'securerandom'
require 'ckb'
require 'colorize'
require 'terminal-table'

MINER_PRIV_KEY = "0x390057c2e04ed67979a71d37b61bdadc6514206425990625384843f48644054b".freeze
BIT = 100_000_000
PURE_TX_CAPACITY = 128 * BIT
SECP_TX_CAPACITY = 336 * BIT
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

  def ==(other)
    tx_hash == other.tx_hash
  end

  def to_s
    "task #{tx_hash} send_at #{send_at} proposed_at #{proposed_at} committed_at #{committed_at}"
  end
end

class WatchPool
  def initialize(apis, height)
    @apis = apis
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
    api = @apis.sample
    block_hash = api.get_block_hash((@height + 1).to_s)
    puts "check block #{@height + 1} #{block_hash}"
    if block_hash.nil?
      return false
    end
    block = api.get_block(block_hash)
    header = block.header
    block_time = BlockTime.new(number: header.number.to_i, timestamp: header.timestamp.to_i)
    proposed_count = block.proposals.select do |proposal_id|
      mark_proposed proposal_id, block_time
    end.count
    proposed_count += block.uncles.map do |uncle|
      uncle.proposals.select do |proposal_id|
        mark_proposed proposal_id, block_time
      end.count
    end.sum
    committed_count = block.transactions.select do |tx|
      mark_committed tx.hash, block_time
    end.count
    @height += 1
    [proposed_count, committed_count]
  rescue StandardError => e
    warn "node #{api} fucked up, retry...#{e}"
    retry
  end

  def wait(tx_hash)
    loop do
      sleep 3 unless poll
      return if @committed.include? tx_hash
    end
  end

  def wait_all
    total_proposed_count = 0
    total_committed_count = 0
    total_waits = @initial.count
    loop do
      if (result = poll)
        proposed_count, committed_count = result
        if proposed_count > 0 || committed_count > 0
          total_proposed_count += proposed_count
          total_committed_count += committed_count
          puts "#{proposed_count} txs proposed(#{total_proposed_count}/#{total_waits}), #{committed_count} txs committed(#{total_committed_count}/#{total_waits})".colorize(:green)
        end
      else
        sleep 3
      end
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

def get_always_success_lock_script(miner_lock_addr: , lock_hash: )
  CKB::Types::Script.generate_lock(
    miner_lock_addr, lock_hash)
end

def get_always_success_cellbase(api, from:, tx_count:, miner_lock_addr:)
  lock_script = get_always_success_lock_script(miner_lock_addr: miner_lock_addr, lock_hash: api.system_script_cell_hash)
  cells = []
  while cells.map{|c| c.capacity.to_i / SECP_TX_CAPACITY}.sum < tx_count
    new_cells = api.get_cells_by_lock_hash(lock_script.to_hash, from.to_s, (from + 20).to_s)
    if new_cells.empty?
      puts "can't found enough cellbase #{tx_count} from #{api.inspect} #{cells}"
      exit 1
    end
    new_cells.reject!{|c| c.capacity.to_i < SECP_TX_CAPACITY }
    cells.concat(new_cells)
    cells.uniq! {|c| c.out_point.to_h}
    from += 20
  end
  cells
end

def build_secp_prepare_tx cells, addr, lock_script_hash:,system_script_out_point:
  inputs = cells.map do |cell|
    CKB::Types::Input.new(
      previous_output: cell.out_point,
      args: [],
      since: "0",
    )
  end

  total_cap = cells.map{|c| c.capacity.to_i}.sum
  # to build 2-in-2-out tx
  per_cell_cap = SECP_TX_CAPACITY / 2
  outputs = (total_cap / per_cell_cap).times.map do |i|
    CKB::Types::Output.new(
      capacity: per_cell_cap.to_s,
      data: "0x".b,
      lock: CKB::Types::Script.generate_lock(
        addr,
        lock_script_hash,
      )
    )
  end

  CKB::Types::Transaction.new(
    version: 0,
    deps: [system_script_out_point],
    inputs: inputs,
    outputs: outputs,
    witnesses: [],
  )
end

def prepare_cells(api, from, count, lock_addr: )
  miner_key = CKB::Key.new(MINER_PRIV_KEY)
  miner_lock_addr = miner_key.address.blake160
  cells = get_always_success_cellbase(api, miner_lock_addr: miner_lock_addr, from: from, tx_count: count)
  if cells.empty?
    puts "can't find cellbase in #{from}"
    exit 1
  end
  puts "found cellbases"
  # produce cells
  tip = api.get_tip_header
  send_time = BlockTime.new(number: tip.number.to_i, timestamp: tip.timestamp.to_i)

  if cells.uniq{|c| c.out_point.to_h}.size != cells.size
    pp cells
    raise "error detect! dup cells #{cells.size - cells.uniq{|c| c.out_point.to_h}.size}"
  end

  tx_tasks = []
  out_points = []
  system_script_out_point = api.system_script_out_point
  cells.each_slice(1).map do |cells|
    tx = build_secp_prepare_tx cells, lock_addr, lock_script_hash: api.system_script_cell_hash, system_script_out_point: system_script_out_point
    tx_hash = api.compute_transaction_hash(tx)
    tx = tx.sign(miner_key, tx_hash)
    tx_hash = api.send_transaction(tx.to_h)
    out_points += tx.outputs.count.times.map{|i| [tx_hash, i]}
    tx_tasks << TxTask.new(tx_hash: tx_hash, send_at: send_time)
  end
  [tx_tasks, out_points]
end

def send_txs(apis, out_points, txs_count, unlock_key:, lock_script:)
  txs = txs_count.times.map do |i|
    # two inputs: i * 2 and i * 2 + 1
    inputs = [
      CKB::Types::Input.new(
        previous_output: CKB::Types::OutPoint.new(
          cell: CKB::Types::CellOutPoint.new(tx_hash: out_points[i * 2][0], index: out_points[i * 2][1])
        ),
        args: [],
        since: "0"
      ),
      CKB::Types::Input.new(
        previous_output: CKB::Types::OutPoint.new(
          cell: CKB::Types::CellOutPoint.new(tx_hash: out_points[i * 2 + 1][0], index: out_points[i * 2 + 1][1])
        ),
        args: [],
        since: "0"
      ),
    ]
    per_cell_cap = SECP_TX_CAPACITY / 2
    outputs = [
      CKB::Types::Output.new(
        capacity: per_cell_cap,
        lock: lock_script
      ),
      CKB::Types::Output.new(
        capacity: per_cell_cap,
        lock: lock_script
      ),
    ]

    CKB::Types::Transaction.new(
      deps: [apis[0].system_script_out_point],
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
        begin
          tx_hash = api.compute_transaction_hash(tx)
          tx = tx.sign(unlock_key, tx_hash)
          count += 1
          if count % 100 == 0
            new_tip = api.get_tip_header 
            if new_tip.timestamp.to_i > tip.timestamp.to_i
              tip = new_tip
            end
          end
          block_time = BlockTime.new(number: tip.number.to_i, timestamp: tip.timestamp.to_i)
          print ".".colorize(:green)
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
  tx_tasks.reject! {|tx| tx.committed_at.nil?}
  # sort txs for calculation
  tx_tasks.sort_by!(&:committed_at)
  last_committed = tx_tasks.last
  puts "Total TPS: #{tx_tasks.size / (last_committed.committed_at.timestamp - first_send.send_at.timestamp)}"
  [20, 40, 60, 80].each do |batch|
    batch_size = tx_tasks.size * batch / 100
    puts "#{batch}% TPS: #{batch_size / (tx_tasks[batch_size - 1].committed_at.timestamp - tx_tasks[0...batch_size].map{|tx| tx.send_at.timestamp}.sort.first)}"
  end
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
  watch_pool = WatchPool.new(apis, tip.number.to_i)
  key = CKB::Key.new(CKB::Key.random_private_key)
  puts "use random generated key #{key.pubkey}"
  lock_addr = key.address.blake160
  puts "generate addr len #{lock_addr.size}"
  puts "prepare #{txs_count} benchmark cells from height #{from}".colorize(:yellow)
  tx_tasks, out_points = prepare_cells(api, from, txs_count, lock_addr: lock_addr)
  tx_tasks.each do |tx_task|
    watch_pool.add(tx_task.tx_hash, tx_task)
  end
  puts "wait prepare tx get confirmed ...".colorize(:yellow)
  puts tx_tasks
  watch_pool.wait_all
  puts "start sending #{txs_count} txs...".colorize(:yellow)
  miner_key = CKB::Key.new(MINER_PRIV_KEY)
  miner_lock_addr = miner_key.address.blake160
  lock_script = CKB::Types::Script.generate_lock(
    miner_lock_addr, api.system_script_cell_hash)
  tx_tasks = send_txs(apis, out_points, txs_count, unlock_key: key, lock_script: lock_script)
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
    from, txs_count, server_list = ARGV[1].to_i, ARGV[2].to_i, ARGV[3]
    apis_tips = if server_list
             server_list = open(server_list).read
             server_ips = server_list.gsub(/\d+\.\d+\.\d+\.\d+/)
             api_tests = server_ips.to_a.product([8122, 8121]).map do |ip, port| 
               Thread.new do
                 begin
                   api_with_tip = Timeout.timeout(10) do
                     api = CKB::API.new(host: "http://#{ip}:#{port}")
                     [api, api.get_tip_header.number.to_i]
                   end 
                   print "*"
                   api_with_tip
                 rescue StandardError => _e
                   print "x"
                   nil
                 end
               end
             end
             api_tests.map(&:value).reject(&:nil?).shuffle
           else
             api_url = ENV['API_URL'] || 'http://localhost:8114'
             api_url.split("|").map do |url| 
               api = CKB::API.new(host: url)
               [api, api.get_tip_header.number.to_i]
             end
           end
    tips = apis_tips.map{|api, tip| tip}.sort
    median_tip = tips[tips.size / 2]
    apis = apis_tips.select{|api, tip| tip >= median_tip}.map{|api, _| api}
    puts "\nuse #{apis.size} servers to run benchmark"
    p apis
    run(apis, from, txs_count)
  elsif command == "stat"
    stat_file = ARGV[1] || DEFAULT_STAT_FILE
    puts "statistics #{stat_file}..."
    tx_tasks = Marshal.load(open(stat_file, "r"))
    statistics(tx_tasks)
  else
    puts "unknown command #{command}"
    puts "try run benchmark: bench.rb run <block height> <count of tx>"
    puts "example: bench.rb run 23005 20"
    puts "try run stat: bench.rb stat <file>"
  end
end
