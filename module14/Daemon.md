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
> task가 실질적으로 실행되는 진입점

      virtual void retire (void)
      {
	delete this;
      }
  };
```
▲ task 인터페이스

또한 스레드에서 진행되는 작업들은 최소 단위로 task를 사용합니다.

일반적으로 `class callable_task : public task<Context>`를 사용하고, 커스텀 task를 만드는 경우에는 task로부터 상속받은 클래스를 만들어 사용합니다.

```cpp
using entry_callable_task = callable_task<entry>;

void
dwb_file_sync_helper_daemon_init ()
{
  cubthread::looper looper = cubthread::looper (std::chrono::milliseconds (10));
  cubthread::entry_callable_task *daemon_task = new cubthread::entry_callable_task (dwb_file_sync_helper_execute);

  dwb_file_sync_helper_daemon = cubthread::get_manager ()->create_daemon (looper, daemon_task);
}
```
dwb_file_sync_helper_daemon_init을 예시로 설명하면, looper를 통해 간격(milliseconds 10)을 지정하고 entry_callable_task(callable_task<entry>)에
`dwb_file_sync_helper_execute` 함수를 넘겨주어 daemon_task를 생성합니다.

이후 `daemon_task->execute()` 를 호출하여 처리해야할 작업인 `dwb_file_sync_helper_execute(entry)`를 호출할 수 있습니다.

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
`RUNNING`<br/>
`SLEEPING`<br/>
`AWAKENING`<br/>

<br/>

`looper`는 대기 시간을 계산하고 실행 상태를 처리하는 객체입니다.
처리할 수 있는 대기 시간 유형은 4가지 종류로<br/>
`INF_WAITS`<br/>
`FIXED_WAITS`<br/>
`INCREASING_WAITS`<br/>
`CUSTOM_WAITS`<br/>
가 있습니다.
	
<br/>

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
<br/>

### Looper & Waiter
	
```cpp
  void daemon::pause (void)
  {
    m_looper.put_to_sleep (m_waiter);
  }
```
	
Daemon의 pause는 위와 같습니다. looper의 put_to_sleep 함수를 호출하고 이때 waiter를 넘겨줍니다.
	
```cpp
void
  looper::put_to_sleep (waiter &waiter_arg)
  {
    if (is_stopped ())
      {
	return;
      }

    assert (m_setup_period);

    cubperf::reset_timept (m_stats.m_timept);

    bool is_timed_wait = true;
    delta_time period = delta_time (0);

    m_setup_period (is_timed_wait, period);

    if (is_timed_wait)
      {
	delta_time wait_time = delta_time (0);
	delta_time execution_time = delta_time (0);

	if (m_start_execution_time != std::chrono::system_clock::time_point ())
	  {
	    execution_time = std::chrono::system_clock::now () - m_start_execution_time;
	  }

	if (period > execution_time)
	  {
	    wait_time = period - execution_time;
	  }

	m_was_woken_up = waiter_arg.wait_for (wait_time);
	
      }
    else
      {
	waiter_arg.wait_inf ();
	m_was_woken_up = true;
      }

    m_start_execution_time = std::chrono::system_clock::now ();
    Looper_statistics.time_and_increment (m_stats, STAT_LOOPER_SLEEP_COUNT_AND_TIME);
  }
```

```cpp
  void
  waiter::wait_inf (void)
  {
    std::unique_lock<std::mutex> lock (m_mutex);
    goto_sleep ();
> 상태를 SLEEPING으로 설정
	
    m_condvar.wait (lock, [this] { return m_status == AWAKENING; });
> condition variable에 wait 로 lock된 뮤텍스를 넘겨주어 무조건 대기 상태로 들어간다.
> wakeup 호출을 통한 AWAKENING 상태 변화가 일어났을 경우 스레드의 대기를 종료한다.
	
    run ();
  }

  bool
  waiter::wait_for (const std::chrono::system_clock::duration &delta)
  {
    if (delta == std::chrono::microseconds (0))
      {
	Waiter_statistics.increment (m_stats, STAT_NO_SLEEP_COUNT);
	return true;
      }

    bool ret;

    std::unique_lock<std::mutex> lock (m_mutex);
    goto_sleep ();
> 상태를 SLEEPING으로 설정

    ret = m_condvar.wait_for (lock, delta, [this] { return m_status == AWAKENING; });
> condition variable에 wait_for 로 lock된 뮤텍스를 넘겨주어 무조건 대기 상태로 들어간다.
> 이때 timeout 또는 wakeup 호출을 통한 AWAKENING 상태 변화가 일어났을 경우 스레드의 대기를 종료한다.
    if (!ret)
      {
	Waiter_statistics.increment (m_stats, STAT_TIMEOUT_COUNT);
      }

    run ();

    return ret;
  }
	
  bool
  waiter::wait_until (const std::chrono::system_clock::time_point &timeout_time)
  {
    std::unique_lock<std::mutex> lock (m_mutex);
    goto_sleep ();
> 상태를 SLEEPING으로 설정
	
    bool ret = m_condvar.wait_until (lock, timeout_time, [this] { return m_status == AWAKENING; });
> condition variable에 wait_until 로 lock된 뮤텍스를 넘겨주어 무조건 대기 상태로 들어간다.
> 이때 지정된 시간까지의 대기 또는 wakeup 호출을 통한 AWAKENING 상태 변화가 일어났을 경우 스레드의 대기를 종료한다.
	
    if (!ret)
      {
	Waiter_statistics.increment (m_stats, STAT_TIMEOUT_COUNT);
      }

    run ();

    return ret;
  }
```
	
<br/>
<br/>

지금까지의 내용을 아래와 같이 그릴 수 있습니다.

![6](https://user-images.githubusercontent.com/12230655/147214782-99e50b75-911e-46b3-8e1b-9e15a5004370.png)

<br/>
<br/>


### create_daemon
	
```cpp
  template<typename Res, typename ... CtArgs>
  inline Res *manager::create_and_track_resource (std::vector<Res *> &tracker, size_t entries_count, CtArgs &&... args)
  {
    check_not_single_thread ();

    std::unique_lock<std::mutex> lock (m_entries_mutex);
> tracker 변경에 앞서 lock

    if (m_available_entries_count < entries_count)
      {
	return NULL;
      }
    m_available_entries_count -= entries_count;
> entry를 차지합니다. 차지할 수 없다면 종료합니다

    Res *new_res = new Res (std::forward<CtArgs> (args)...);
> create_daemon에서 호출된 경우 Res는 daemon이 되고 각 인자를 생성자로 하는 객체를 생성합니다

    tracker.push_back (new_res);
> tracker(m_daemons)에 넣어 관리합니다.
	
    return new_res;
  }

	
  daemon *
  manager::create_daemon (const looper &looper_arg, entry_task *exec_p, const char *daemon_name /* = "" */,
			  entry_manager *context_manager /* = NULL */)
  {
#if defined (SERVER_MODE)
    if (is_single_thread ())
      {
	assert (false);
	return NULL;
      }
    else
      {
	if (context_manager == NULL)
	  {
	    context_manager = m_daemon_entry_manager;
	  }

	return create_and_track_resource (m_daemons, 1, looper_arg, context_manager, exec_p, daemon_name);
> tracker로 m_daemons 을 넘겨줘서 1 엔트리만큼을 차지하는 데몬을 생성합니다.
      }
#else // not SERVER_MODE = SA_MODE
    assert (false);
    return NULL;
#endif // not SERVER_MODE = SA_MODE
  }
```
	
<br/>
<br/>

### dwb_flush_block_daemon_init

```cpp
void
dwb_flush_block_daemon_init ()
{
  cubthread::looper looper = cubthread::looper (std::chrono::milliseconds (1));
  dwb_flush_block_daemon_task *daemon_task = new dwb_flush_block_daemon_task ();

  dwb_flush_block_daemon = cubthread::get_manager ()->create_daemon (looper, daemon_task);
}
```
	
위는 dwb_flush_block_daemon 의 초기화 지점입니다.

```cpp
namespace cubthread {
  using entry_task = task<entry>;
}

class dwb_flush_block_daemon_task: public cubthread::entry_task
{
  private:
    PERF_UTIME_TRACKER m_perf_track;

  public:
    dwb_flush_block_daemon_task ()
    {
      PERF_UTIME_TRACKER_START (NULL, &m_perf_track);
    }

    void execute (cubthread::entry &thread_ref) override
    {
      if (!BO_IS_SERVER_RESTARTED ())
        {
	  return;
        }
> 서버 boot가 끝날 때까지 대기

      PERF_UTIME_TRACKER_TIME (NULL, &m_perf_track, PSTAT_DWB_FLUSH_BLOCK_COND_WAIT);

      if (prm_get_bool_value (PRM_ID_ENABLE_DWB_FLUSH_THREAD) == true)
> cubrid 시스템 내 PRM_ID_ENABLE_DWB_FLUSH_THREAD 번째 파라미터 값을 bool로 확인
        {
	  if (dwb_flush_next_block (&thread_ref) != NO_ERROR)
	    {
	      assert_release (false);
	    }
	> dwb_flush_next_block함수를 호출
        }

      PERF_UTIME_TRACKER_START (&thread_ref, &m_perf_track);
    }
};

	
static int
dwb_flush_next_block (THREAD_ENTRY * thread_p)
{
  unsigned int block_no;
  DWB_BLOCK *flush_block = NULL;
  int error_code = NO_ERROR;
  UINT64 position_with_flags;

start:
  position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
  if (!DWB_IS_CREATED (position_with_flags) || DWB_IS_MODIFYING_STRUCTURE (position_with_flags))
    {
      return NO_ERROR;
    }
> 플래그를 체크해서 dwb가 만들어지지 않았거나, 만드는 도중이라면 종료

  dwb_get_next_block_for_flush (thread_p, &block_no);
> dwb_Global.next_block_to_flush 번째 블록이 꽉 찼으면 block_no = dwb_Global.next_block_to_flush
> 블록이 아직 꽉 차지 않아서 flush 할 수 없다면, block_no = DWB_NUM_TOTAL_BLOCKS
	
  if (block_no < DWB_NUM_TOTAL_BLOCKS)
    {
> 블록이 flush 가능하다면
      flush_block = &dwb_Global.blocks[block_no];

      assert (flush_block != NULL && flush_block->count_wb_pages == DWB_BLOCK_NUM_PAGES);

      if (DWB_GET_PREV_BLOCK (flush_block->block_no)->version < flush_block->version
	  || ((DWB_GET_PREV_BLOCK (flush_block->block_no)->version == flush_block->version)
	      && (flush_block->block_no > DWB_GET_PREV_BLOCK_NO (flush_block->block_no))))
	{
	  if (DWB_GET_PREV_BLOCK (flush_block->block_no)->count_wb_pages != 0)
	    {
	      assert_release (false);
	    }
	}
> 정확하게는 모르겠는데 아마 블록의 version은 블록이 flush 된 횟수로 보임
> (이전 블록 flush 횟수) < (flush 블록 flush 횟수) 또는
> (이전 블록 flush 횟수) == (flush 블록 flush 횟수) && (이전 블록 번호) < (flush 블록 번호)
> 일 때 이전 블록이 모두 flush 되지 않은 경우에 crash를 일으키는 것으로 보아
> 이전 블록의 flush에서 (일부) flush를 하지 못한 경우에 처리해주는 것으로 추측됨

      error_code = dwb_flush_block (thread_p, flush_block, true, NULL);
> flush

      if (error_code != NO_ERROR)
	{
	  dwb_log_error ("Can't flush block = %d having version %lld\n", flush_block->block_no, flush_block->version);

	  return error_code;
	}

      dwb_log ("Successfully flushed DWB block = %d having version %lld\n",
	       flush_block->block_no, flush_block->version);

	> 다시 처음부터 진행해서 flush 가능한 블록이 있는 지 확인
      goto start;
    }

  return NO_ERROR;
}
```
	
	
<br/>
<br/>

### dwb_flush_block_daemon_init

flush 되어 dwb_Global.file_sync_helper_block에 예약된 블록을 disk와 동기화해줍니다.

해당 daemon이 호출되어 flush 된 블록이 disk와 동기화 되기 전에 flush가 호출되게 되면 daemon이 사용가능한 경우 대기하거나 flush 된 이전 블록에 대해서 내부적으로 동기화를 진행하고 현재 블록에 대해 flush를 진행합니다

```cpp
void
dwb_file_sync_helper_daemon_init ()
{
  cubthread::looper looper = cubthread::looper (std::chrono::milliseconds (10));
  cubthread::entry_callable_task *daemon_task = new cubthread::entry_callable_task (dwb_file_sync_helper_execute);

  dwb_file_sync_helper_daemon = cubthread::get_manager ()->create_daemon (looper, daemon_task);
}
```

```cpp
	using entry_callable_task = callable_task<entry>;
	
  template <typename Context>
  class callable_task : public task<Context>
  {
    public:
      using exec_func_type = std::function<void (Context &)>;

      callable_task () = delete;

      template <typename F>
      callable_task (const F &f, bool delete_on_retire = true);
      template <typename F>
      callable_task (F &&f, bool delete_on_retire = true);

      template <typename FuncExec, typename FuncRetire>
      callable_task (const FuncExec &fe, const FuncRetire &fr);
      template <typename FuncExec, typename FuncRetire>
      callable_task (FuncExec &&fe, FuncRetire &&fr);

      void execute (Context &ctx) final
      {
	m_exec_f (ctx);
      }

      void retire () final
      {
	m_retire_f ();
      }

    private:
      std::function<void (Context &)> m_exec_f;
      std::function<void (void)> m_retire_f;
  };
```
	
callable_task는 생성자에서 인자로 함수를 받아 저장하고 이를 execute에서 호출합니다.
	
이 경우에는 `m_exec_f (ctx);`로 함수 `dwb_file_sync_helper_execute` 를 호출하게 됩니다.
	
```cpp
dwb_file_sync_helper_execute (cubthread::entry &thread_ref)
{
  if (!BO_IS_SERVER_RESTARTED ())
    {
      return;
	> 서버 boot가 끝날 때까지 대기
    }

  if (prm_get_bool_value (PRM_ID_ENABLE_DWB_FLUSH_THREAD) == true)
> cubrid 시스템 내 PRM_ID_ENABLE_DWB_FLUSH_THREAD 번째 파라미터 값을 bool로 확인
    {
      dwb_file_sync_helper (&thread_ref);
> dwb_file_sync_helper 함수를 호출
    }
}
```

```cpp
static int
dwb_file_sync_helper (THREAD_ENTRY * thread_p)
{
  position_with_flags = ATOMIC_INC_64 (&dwb_Global.position_with_flags, 0ULL);
  if (!DWB_IS_CREATED (position_with_flags) || DWB_IS_MODIFYING_STRUCTURE (position_with_flags))
    {
      return NO_ERROR;
    }
> dwb가 없거나 만들어지는 중이라면 대기

  block = (DWB_BLOCK *) dwb_Global.file_sync_helper_block;
  if (block == NULL)
    {
      return NO_ERROR;
    }
> 변수 dwb_Global.file_sync_helper_block 가 비어있다면

	..........
> fsync를 사용하여 버퍼와 disk를 동기화
	
	
  (void) ATOMIC_TAS_ADDR (&dwb_Global.file_sync_helper_block, (DWB_BLOCK *) NULL);
> dwb_Global.file_sync_helper_block를 NULL로 비움
	
  return NO_ERROR;
}
```
