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

Example: 

> testnet is still on early stage, the benchmark result maybe change frequently

```
statistics...
Total: 2000
Total TPS: 57
+------------------+---------------------------+---------------------------+---------------------------+---------------------------+-----+
| type             | avg                       | median                    | fastest 20%               | slowest 20%               | tps |
+------------------+---------------------------+---------------------------+---------------------------+---------------------------+-----+
| Proposed at      | 2019-04-27 00:10:53 +0800 | 2019-04-27 00:10:53 +0800 | 2019-04-27 00:10:53 +0800 | 2019-04-27 00:10:53 +0800 | 153 |
| Committed at     | 2019-04-27 00:11:15 +0800 | 2019-04-27 00:11:15 +0800 | 2019-04-27 00:11:15 +0800 | 2019-04-27 00:11:15 +0800 | 57  |
| Per tx proposed  | 13.0                      | 13                        | 13.0                      | 13.0                      | 153 |
| Per tx committed | 35.0                      | 35                        | 35.0                      | 35.0                      | 57  |
+------------------+---------------------------+---------------------------+---------------------------+---------------------------+-----+
```

