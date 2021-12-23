## DAEMON

```
데몬이란 사용자가 직접적으로 제어하지 않고, 백그라운드에서 돌면서 여러 작업을 하는 프로그램을 말한다.
```

<br/>

### dwb_daemons_init

```cpp
void
dwb_flush_block_daemon_init ()
{
  cubthread::looper looper = cubthread::looper (std::chrono::milliseconds (1));
  dwb_flush_block_daemon_task *daemon_task = new dwb_flush_block_daemon_task ();

  dwb_flush_block_daemon = cubthread::get_manager ()->create_daemon (looper, daemon_task);
}

void
dwb_file_sync_helper_daemon_init ()
{
  cubthread::looper looper = cubthread::looper (std::chrono::milliseconds (10));
  cubthread::entry_callable_task *daemon_task = new cubthread::entry_callable_task (dwb_file_sync_helper_execute);

  dwb_file_sync_helper_daemon = cubthread::get_manager ()->create_daemon (looper, daemon_task);
}

void
dwb_daemons_init ()
{
  dwb_flush_block_daemon_init ();
  dwb_file_sync_helper_daemon_init ();
}
```
▲ dwb daemon 을 초기화하는 부분

<br/>

### Cubrid 에서의 Thread

Daemon 등을 이해하기 위해서는 Cubrid의 스레드 구조에 대해 이해가 필요해 보입니다.

<br/>

![2](https://user-images.githubusercontent.com/12230655/147192226-d25b50a0-fe7a-44c1-a0e6-2224a6a58a19.png)

우선 Cubrid 의 스레드는 아래와 같은 cubthread 라는 네임스페이스 안에서 처리됩니다

<br/>

![3](https://user-images.githubusercontent.com/12230655/147192636-11c04418-a570-44c6-9f29-e264ff921aba.png)

core(worker sub-group)을 관리하는 worker_pool과 daemon은 cubthread 내에 있는 manager 클래스에서 관리됩니다.

manager 인스턴스는 `void initialize (entry *&my_entry)` 에서 초기화되고 static으로 선언된 Manager 포인터가 받게 됩니다.

<br/>

![4](https://user-images.githubusercontent.com/12230655/147193697-10f4dff1-ad91-4d69-99ae-0274368ba524.png)

`entry_workerpool *`의 벡터와 `daemon *`의 벡터가 manager class 내에 존재합니다.
이 벡터들을 사용하여 각 entry_workerpool와 daemon에 대한 정보를 관리합니다.

실제 작업들은 하위 클래스들에서 이뤄지고 manager에서 실질적인 스레드 작업은 없는 것으로 보입니다.

함수 `create_and_track_resource`는 manager 내에서의 daemon, workerpool 리소스 추가작업 등에 사용됩니다.

함수 `push_task` `push_task_on_core` 는 manager 내에서 각 workerpool로 작업을 넘겨줄 때 호출됩니다. 

<br/>

