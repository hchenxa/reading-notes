---
title: Producer
nav_exclude: true
permalink: /kafka/producer/
---

# Kafka 生产者

## 原理
![producer]({{ site.baseurl }}/kafka/images/producer/producers.png)
工作流程大致如下：
1. 首先在main线程中创建了一个Producer对象
2. 调用send方法来发送数据
3. 发送数据过程中，根据生产环境的需求来决定是否需要拦截器，可选项。
4. 通过序列化器对数据进行序列化，一般都是使用Build-in的序列化器进行序列化
5. 当数据发往不同的分区前，需要分区器来决定数据应该发送到哪些分区。
6. 数据会先发送到一个缓冲队列中，缓冲队列的默认大小是32Mb,每批次的大小是16KB
7. sender线程会主动拉取数据。
8. 拉取数据需要满足两个条件。
   1. `batch.size`：只有数据积累到`batch.size`之后，sender才会发送数据，默认大小为16K; 
   2. `linger.ms`：如果数据没有达到`batch.size`,sender等待`linger.ms`设置的时间到了以后就会发送数据，单位ms,默认值为0ms,表示没有延迟。
9.  发送数据的时候，队列里面的数据以节点的方式进行数据发送。发送过去之后，如果kafka集群没有及时应答，NetworkClient里面最多可以缓存5个请求。
10. 数据通过Selector发送到集群，集群开始做副本同步。同步完成后进行应答，应答的策略有三种。
    1.  0: 生产者发送过来的数据，不需要等数据落盘应答。
    2.  1: 生产者发送过来的数据，Leader收到数据后应答。
    3.  -1(all): 生产者发送过来的数据，Leader和ISR队列里面的所有节点收齐数据以后应答。
11. 应答如果成功，则会会请求删除，并且把队列里数据删掉。如果应答失败，有重试机制，默认的重试测试为Int的最大值，直到成功为止。

## 异步发送和回调异步发送
回调函数会在producer收到ack时调用，为异步调用，有两个参数，分别是元数据信息和异常信息，如果Exception为null,说明消息发送成功，否则，说明消息发送失败。
## 同步发送
和异步发送的区别是，必须等数据发送完毕后，就等待消息队列里面的数据发送结束，才会发新的数据到消息队列中。
## 分区
分区器的好处：
- 便于合理使用存储资源，每个partition在一个Broker上存储，可以把海量的数据按照分区切割成一块一块数据存储在多台broker上。合理控制分区的任务，可以实现负载均衡的效果。
- 提高并行度，生产者可以以分区为单位发送数据；消费者可以以分区为单位进行数据消费
## 分区策略
- 默认的分区器DefaultPartitioner
  - 如果指定了分区，就使用指定的这个分区
  - 如果没有指定分区，但设置了key,通过对key的hash值对设置的分区数进行取余得到分区
  - 如果既没有指定分区，也没有Key,则按照粘滞的方式(sticky partition)获取分区，直到当前批次的数据满了
## 自定义分区
实现步骤：
1. 定义类实现Partitioner接口.
2. 重写partition()方法.
## 生产经验
- 提高吞吐量
  - 通过修改batch.size和linger.ms来提高吞吐量，比如batch.size从默认的16K增大到32K，等待时间从0ms增加到5-100ms.
  - 发送数据时进行压缩: compression.type压缩为snappy.
  - 提高缓冲区的大小: 从默认的32Mb增大到64Mb.
- 数据可靠性
![ack1]({{ site.baseurl }}/kafka/images/producer/ack.png)
![ack2]({{ site.baseurl }}/kafka/images/producer/ack2.png)
  - ack=0: 可靠性差，效率高
  - ack=1: 可靠性中等，效率中等
  - ack=-1: 可靠性高，效率低

在生产环境中，ack=0很少使用;ack=1一般用于创书普通日志，允许丢个别数据；ack=-1，一般用于可靠性要求很高的场景，比如货币交易之类的。
 
- 数据去重

当ack=-1的时候，生产者发送过来的数据，leader和ISR队列里面的所有节点收齐数据后应答。当Leader在应答的时候挂了，则会选择一个新的Leader出来，但produer这时并没有收到leader的应答信息，所以会重新发一次消息，那新的leader可能就会有两个相同的消息。
![数据去重]({{ site.baseurl }}/kafka/images/producer/数据去重.png)

  - 数据传递语义
    - 至少一次（At least Once）= ACK级别设置为-1 + 分区副本大于等于2 + ISR里应答的最小副本数量大于等于2
    - 最多一次（At Most Once）= ACK级别设置为9
    
    总结：
    - At Least Once可以保证数据不丢失，但是不能保证**数据不重复**
    - At Most Once可以保证数据不重复，但是不能保证**数据不丢失**

    精确一次（Exactly Once）：Kafka0.11版本以后，引入了：**幂等性和事务**。
  - 幂等性
  
    生产者不论向Broker发送多少次重复数据，Broker端都会持久化一条数据，保证了不重复。
    Exactly Once = 幂等性 + ACK（-1） + 分区副本数 >=2 + ISR最小副本 >=2

    重复数据的判断标准：具有<PID, Partition, SeqNumber>相同主键的消息提交时，Broker只会持久化一条。其中PID是Kafka每次重启都会分配一个新的；Partition表示分区号；Sequence Number是单调自增的。所以，幂等性只能保证**在单分区单会话内不重复**。

    开启参数`enable.idempotence`就能打开幂等性。

  - 生产者事务

    **开启事务的前提是必须先开启幂等性。**
    ![事务]({{ site.baseurl }}/kafka/images/producer/事务.png)
    
- 数据有序
1. 未开启幂等性
   `max.in.flight.requests.per.connection`需要设置为1
2. 开启幂等性
   `max.in.flight.requests.per.connection`需要设置小于等于5
   因为，启用幂等性以后，kafka服务端会缓存producer发来的最近5个request的元数据，所以无论如何，都可以保证最近5个request的数据都是有序的。
   
![乱序]({{ site.baseurl }}/kafka/images/producer/乱序.png)