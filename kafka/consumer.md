## Kafka消费者

### kafka消费方式

- pull mode
  
  consumer采用从Broker中主动拉取数据,主要因为消费者消费数据的能力不同.如果kafka中没有数据,消费者会陷入循环中,一直返回空数据.

- push mode
  
  由于broker决定消息发送速率,很难适应所有消费者的消费速率,例如推送的速度是50m/s,速度慢的消费者就没法处理消息了.

### 消费者总体工作流程

- 一个消费者可以消费一个或者多个分区的消息.
- 消费者与消费者之间是完全独立的,消费消息的时候不会产生冲突.
- 消费者组里面的消费者不能消费同一个分区的消息,每个分区的数据智能由消费者组中的一个消费者消费.
- 每个消费者的offset由消费者提交到topic中保存. `__consumer_offsets`.

### 消费者组原理

consomer group(CG):消费者组,有多个consomer组成,形成一个消费者组的条件,是所有的消费者的groupid相同.

- 消费者组内每个消费者负责消费不同分区的消息,一个分区只能由一个组内的消费者消费.
- 消费者组之间互不影响.所有的消费者都属于某个消费者组,也就是说消费者组是逻辑上的一个订阅者.
- 如果消费者组中的消费者数量超过了topic的分区数量,则有一部分消费者就会闲置,不会接受到任何消息.

### 消费者组的初始化流程

coordinator: 辅助实现消费者组的初始化和分区的分配

coordinator的节点选择 = groupid的hashcode % 50 （50是默认的__consumer_offsets的分区数量）

例如: groupid的hashcode的值=1, 1 % 50 = 1, 那么`__consumer_offsets` 主题的1号分区在哪个broker上,就选择这个节点的coordinator作为这个消费者组的leader, 消费者组下的所有的消费者提交offsets的时候就往这个分区去提交offset.

- 消费者组中的每个consumer都会发送一个`JoinGroup` 请求到coordinator.
- coordinator选出一个consumer作为leader.
- coordinator把要消费的topic信息发送给consumer leader.
- consumer leader负责定制一个消费方案,来决定消费者中的消费者怎么对分区进行消费.
- consumer leader把计划发送给coordinator.
- coordinator把消费计划进行下发,发送给消费者组中的每个消费者.
- 每个消费者通过心跳机制,和coordinator保持通信,一旦通信超时(`session.timeout.ms=45s`),该消费者会被移除,并切开时触发再平衡;或者消费者处理消息的时间过长(`max.poll.interval.ms=5m`),也会触发再平衡.

### 消费者组的详细消费流程

- 消费者组首先创建一个消费者组网络客户端`ConsumerNetworkClient`,用于和kafka集群进行交互.
- 调用`sendFetches`方法发送初始化抓取数据
  - `fetch.min.bytes`,每批次最小抓取大小,默认1字节.
  - `fetch.max.wait.ms`,一批数据最小值为达到的超时时间,默认`500ms`.
  - `fetch.max.bytes`,每批次最大抓取的大小,默认`50Mbi`.
- `ConsumerNetworkClient`调用`send`方法发送请求,通过回掉方法`onSuccess`把对应的结果拉取回来`CompletedFetches`,拉取回来的数据会放到一个消息队列里面`queue`
- 消费者通过`FetchRecords`从队列中抓取数据.
  - `max.poll.records`一次拉取数据返回消息的最大条数.默认500.
  - `parseRecord`,反序列化从`queue`中来回来的数据.
  - 经过`interceptors`拦截器.
  - 最后处理数据.

### 消费者API

- 主题订阅
  
  ```go

  ```
- 分区订阅
  
  ```go

  ```
- 消费者组
  
  ```go

  ```

### 分区的分配以及再平衡

Kafka有4种主流的分区分配策略: `Range`, `RoundRobin`, `Sticky`, `CooperativeSticky`. 可以通过配置参数`partition.assignment.strategy`来修改分区的分配策略,默认策略是`Range`+`CooperativeSticky`.

- `Range`
  
  `Range` **是对每一个topic而言的**,首先对同一个topic里面的分区按照序号进行排序,并且对消费者按照字母顺序进行排序.

  例如,有7个分区,3个消费者,排序后的分区会是,0,1,2,3,4,5,6; 消费者排序完是c0, c1, c2. 通过分区数除以消费者数来决定每个消费者应该消费几个分区.如果除不尽,那么前面几个消费者将会多消费一个分区.

问题,如果多个topic, 容易造成数据倾斜,就是说某个消费者会比其他消费者多消费N个Topic的数据.

- `RoundRobin`
 
  `RoundRobin` **针对所有的topic而言的**, 首先采用的是轮询分区策略,是吧所有的partition和所有的consumer都列出来,然后按照hashcode进行排序,最后通过轮询算法来分配partition给各个消费者.

- `Sticky`

  `Sticky` **针对所有的topic而言的**, 首先会尽量均衡的放置分区到消费者上面,在出现同一个消费者组内消费者出现问题的时候,会尽量保持原有分配的分区不发生变化.

### offsets

- offsets默认维护位置

从Kafka0.9版本开始以后,consumer默认把offsets保存在kafka的一个内置的topic中,该topic为`__consumer_offsets` ,在0.9之前,consumer默认将offsets保存在zookeeper中.

`__consumer_offsets`主题里面采用key和value的方式存储数据.Key是group.id+topic+分区号,value是当前offsets的值.每隔一段时间,Kafka内部会对这个topic进行compact, 也就是每个group.id+topic+分区号保留最新的数据.

在配置文件`config/consumer.properties`中添加配置`exclude.internal.topies=false`, 默认是`true`,表示不能消费系统主题.为了查看消费系统主题数据,所以该参数修改为`false`.

- 自动offsets提交

为了使用户能够专注于自己的业务逻辑,kafka提供了自动提交offsets的功能

1) `enable.auto.commit`: 是否开启自动提交offsets功能,默认是true.
2) `auto.commit.interval.ms`: 自动提交offsets的时间间隔,默认是5s.

- 手动offsets提交

虽然自动提交offsets十分简单便利,但由于其是基于时间提交的,开发人员难以把握offsets提交的时机.因此Kafka还提供了手动提交offsets的API.

手动提交offsets的方法有两种:

1) commitSync(同步提交): 等待offsets提交完毕,再去消费下一批数据.
2) commitAsync(异步提交): 发送完提交offsets请求后,就开始消费下一批数据.

相同点:对会将本次提交的一步数据最高的偏移量提交.
不同点:同步提交阻塞当前线程,一直到提交成功,并且会自动失败重试;异步提交没有失败重试机制,可能提交失败.

- 指定offsets消费

`auto.offset.reset` = `earliest`|`latest`|`none`, 默认是`latest`.

当Kafka中没有初始偏移量(消费者组第一次消费)或服务器上不再存在当前偏移量的时候(例如该数据已被删除)

1) `earliest`: 自动将偏移量重置为最早的偏移量. `--from-begining`
2) `latest`: 自动将偏移量重置为最新的偏移量.
3) `none`: 如果未找到消费者组的先前的偏移量,则向消费者抛出异常.


```java
// 指定位置进行消费
Set<TopicPartition> assignment = kafkaConsumer.assignment();

// 保证分区分配方案制定完毕

while (assignment.size() == 0) {
  kafkaConsumer.pull(Duration.offSeconds(1));
  assignment = kafkaConsumer.assignment();
}

for (TopicPartition topicPartition : assignment) {
  kafkaConsumer.seek(topicPartition, offset: 100);
}

// 消费数据
while (true) {
  ConsumerRecords<String, String> consumerRecords = kafkaConsumer.poll(Duration.ofSeconds(1));

  for (ConsumerRecord<String, String> consumerRecord : consumerRecords) {
    System.out.Println(consumerRecords);
  }
}
```

- 指定时间进行消费

在生产环境中,会遇到最近消费的几个小时的数据异常,想重新按照时间消费,例如要求消费一天前的数据.

```java
HashMap<TopicPartition, Long> topicPartitionLongHashMap = new HashMap<>();

// 封装对应的集合
for(TopicPartition topicPartition : assignment) {
  topicPartitionLongHashMap.put(topicPartition, System.currentTimeMillis() - 1 * 24 * 3600 * 1000);
}

Map<TopicPartition, OffsetAndTimestamp> topicPartitionOffsetAndTimestampMap = kafkaConsumer.offsetsForTimes(topicPartitionLongHashMap)

// 指定消费的offset
for(TopicPartition topicPartition : assignment) {
  OffsetAndTimestamp offsetAndTimestamp = topicPartitionOffsetAndTimestampMap.get(topicPartition);
  kafkaConsumer.seek(topicPartition, offsetAndTimestamp.offset());
}
```

- 漏消费和重复消费

1) 漏消费: 先提交了offset后消费,有可能会造成数据的漏消费.比如手动设置了offset提交,当Offset提交的时候,数据还在内存中没有落盘,此时刚好消费者线程被kill掉,那么offset已经提交,但是数据未处理,导致这部分内存中的数据丢失.
2) 重复消费: 已经消费了数据,但是可能offset没提交. 自动提交offset会引起.

如果想完成Consumer端的精准一次性消费,那么需要kafka消费端将消费过程和提交Offset的过程原子绑定.需要将kafka的offset保存到支持事物的自定义介质.

### 数据积压的处理

- 如果kafka消费能力不足,可以考虑增加topic的分区数,并且同时提升消费者组的消费者数量.消费者数=分区数.
- 如果是下游的数据处理不及时,可以提高每批次拉取的数量.批次拉取的数据过少使处理的数据小于生产的数据,也会造成数据积压.
