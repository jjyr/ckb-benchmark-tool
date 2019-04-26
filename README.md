Benchmark CKB network TPS
=======

## Setup

```
git clone https://github.com/jjyr/ckb-benchmark-tool.git
cd ckb-benchmark-tool && bundle install
```

## Usage

1, Start a local CKB node.


2, Send transactions

```
./bench.rb run <block_number> <txs_count>
```

1. find cellbases from `block_number`, then prepare a bench of cells
2. send `txs_count` transactions to node, then wait for committed.

3, Run statistics

```
./bench.rb stat
```

