# Broker

## 工作流程
![broker](./images/broker.png)

1. 每台kafka broker启动的时候都会注册到zk里面。
2. 每个broker上都有controller, 不同broker上的controller需要决定谁是leader, 一般谁先注册拿到锁谁就是leader.
3. 由选取出来的controller leade开始监听brokers节点的变化。
4. controller决定leader选举，选举规则为：在ISR存活的前提下，按照AR（所有副本的统称）排在前面的优先顺序选择。
5. 选举出leader以后，controller讲节点信息上传到zk上
6. 其他controller从zk同步相关的信息
7. producer开始发送信息，follower从leader里面同步数据，数据以log的形式进行存储，按照1G的容量划分成Segment，其中包含一个.index文件和.log文件，便于快速查找数据。数据接受完了以后会发个应答。
8. 当当前的leader挂了的时候，存活的controller就能监听到节点变化
9. 并且从zk里面获取ISR
10. 然后进行新的leader的选举
11. 然后更新leader的信息到zk

## 副本
1. 副本的作用：提高数据的可靠性
2. 默认副本为1，生产环境一般配置2个。太多副本会增加磁盘存储空间，增加网络传输负担，降低效率。
3. 副本有leader和follower。数据只会发给leader, 然后follower找leader同步数据
4. Kafka分区所有副本统称为AR（Assigned Replicas）

AR = ISR + OSR
- ISR(On-Sync Replicas): 表示和Leader保持同步的**Follower集合**。`replica.lag.time.max.ms`可以设置ISR时间，默认为30s,超过这个时间，follower会从ISR里面踢出去。
- OSR(Out-of-Sync Replicas): 表示Follower和Leader副本同步时，延迟过多的副本。

## 文件存储