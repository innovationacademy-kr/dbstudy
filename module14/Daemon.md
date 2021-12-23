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

Daemon 등을 이해하기 위해서는 Cubrid의 스레드 작업 구조에 대해 이해가 필요해 보입니다.

<br/>

![2](https://user-images.githubusercontent.com/12230655/147192226-d25b50a0-fe7a-44c1-a0e6-2224a6a58a19.png)

우선 Cubrid 의 스레드는 아래와 같은 cubthread 라는 네임스페이스 안에서 처리됩니다

<br/>
<br/>

### Task

![2-1](https://user-images.githubusercontent.com/12230655/147211556-b17214a0-d9f8-497b-8626-3314ccd3fbda.png)
▲ task

```cpp
  using entry_task = task<entry>;
  
  template <typename Context>
  class task
  {
    public:
      using context_type = Context;

      task (void) = default;

      virtual ~task (void) = default;

      virtual void execute (context_type &) = 0;

      virtual void retire (void)
      {
	delete this;
      }
  };
```
▲ task 인터페이스

또한 스레드에서 진행되는 작업들은 최소 단위로 task를 사용합니다.

일반적으로 `class callable_task : public task<Context>`를 사용하고, 커스텀 task를 만드는 경우에는 task로부터 상속받은 클래스를 만들어 사용합니다.


<br/>
<br/>

### Manager

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
<br/>

### Daemon

![5](https://user-images.githubusercontent.com/12230655/147200131-003f9267-597f-4aed-ba8c-a7f406325777.png)

위처럼 하나의 Daemon은 하나의 스레드, 하나의 waiter, 하나의 looper를 가지고 있습니다.

우선 위 3가지에 대해 설명합니다.

<br/>

`thread`는 Daemon::loop_with_context (or ::loop_without_context)로 task를 계속 진행합니다.

<br/>

`waiter`는 대기 작업을 진행해주는 객체입니다.
condition_variable에 .wait_for .wait_until를 통해 무조건 lock이 걸린 뮤텍스와 타임아웃, 조건을 넘겨주어 대기를 처리합니다.

<br/>

`looper`는 대기 시간을 계산하고 실행 상태를 처리하는 객체입니다.
처리할 수 있는 대기 시간 유형은 4가지 종류로<br/>
`무기한 대기`<br/>
`고정된 값 만큼 대기`<br/>
`지정된 값들(최대 3개)을 순회`<br/>
`커스텀 함수를 이용해 계산된 대기`<br/>
가 있습니다.


아래는 daemon의 전반적인 초기화 부분입니다.

```cpp
  template <typename Context>
  daemon::daemon (const looper &loop_pattern_arg, context_manager<Context> *context_manager_arg,
		  task<Context> *exec, const char *name /* = "" */)
    : m_waiter ()
    , m_looper (loop_pattern_arg)
    , m_func_on_stop ()
    , m_thread ()
    , m_name (name)
    , m_stats (daemon::create_statset ())
  {
    m_thread = std::thread (daemon::loop_with_context<Context>, this, context_manager_arg, exec, m_name.c_str ());
>   스레드를 시작하고 m_thread에 저장.
>   스레드는 daemon::loop_with_context<Context>(this, context_manager_arg, exec, m_name.c_str()) 꼴이 됩니다.
  }

  template <typename Context>
  void
  daemon::loop_with_context (daemon *daemon_arg, context_manager<Context> *context_manager_arg,
			     task<Context> *exec_arg, const char *name)
  {
    (void) name;

    Context &context = context_manager_arg->create_context ();
>   새 context 등록

    daemon_arg->m_func_on_stop = std::bind (&context_manager<Context>::stop_execution, std::ref (*context_manager_arg),
					    std::ref (context));
>   실행 정지 시의 콜백 함수 설정
              
    daemon_arg->register_stat_start ();
    
    while (!daemon_arg->m_looper.is_stopped ())
>   looper 의 상태가 정지가 아니면
      {
	exec_arg->execute (context);
> task->execute 를 통해 작업 실행

	daemon_arg->register_stat_execute ();

	daemon_arg->pause ();
> daemon->pause 를 호출하여 스레드를 휴식 (looper->waiter 방향으로 정지)
	daemon_arg->register_stat_pause ();
      }

    context_manager_arg->retire_context (context);
    exec_arg->retire ();
> context 제거
  }
```

<br/>

지금까지의 내용을 아래와 같이 그릴 수 있습니다.

