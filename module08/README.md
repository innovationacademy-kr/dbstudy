``` C
/* The double write buffer structure. */
typedef struct double_write_buffer DOUBLE_WRITE_BUFFER;
struct double_write_buffer
{
  bool logging_enabled; /* logging_enabled 를 false 로 설정 */
  DWB_BLOCK *blocks;		/* The blocks in DWB. */
  unsigned int num_blocks;	/* The total number of blocks in DWB - power of 2. */
  unsigned int num_pages;	/* The total number of pages in DWB - power of 2. */
  unsigned int num_block_pages;	/* The number of pages in a block - power of 2. */
  unsigned int log2_num_block_pages;	/* 로그 from block number of pages. */
  volatile unsigned int blocks_flush_counter;	/* The blocks flush counter. */
  volatile unsigned int next_block_to_flush;	/* Next block to flush */

  pthread_mutex_t mutex;	/* The mutex to protect the wait queue. */
  DWB_WAIT_QUEUE wait_queue;	/* The wait queue, used when the DWB structure changed. */

  UINT64 volatile position_with_flags;
  /* The current position in double write buffer and flags. Flags keep the
	* state of each block (started, ended), create DWB status, modify DWB status.
	*/
  dwb_hashmap_type slots_hashmap;	/* The slots hash. */
  int vdes;			/* The volume file descriptor. */

  DWB_BLOCK *volatile file_sync_helper_block;	/* The block that will be sync by helper thread. */

  // *INDENT-OFF*
  double_write_buffer ()
    : logging_enabled (false)
    , blocks (NULL)
    , num_blocks (0)
    , num_pages (0)
    , num_block_pages (0)
    , log2_num_block_pages (0)
    , blocks_flush_counter (0)
    , next_block_to_flush (0)
    , mutex PTHREAD_MUTEX_INITIALIZER
    , wait_queue DWB_WAIT_QUEUE_INITIALIZER
    , position_with_flags (0)
    , slots_hashmap {}
    , vdes (NULL_VOLDES)
    , file_sync_helper_block (NULL)
  {
  }
  // *INDENT-ON*
};

static DOUBLE_WRITE_BUFFER dwb_Global;
```

### Wait Queue
```C
/* DWB queue.  */
typedef struct double_write_wait_queue DWB_WAIT_QUEUE;

struct double_write_wait_queue
{
  DWB_WAIT_QUEUE_ENTRY *head;	/* Queue head. */
  DWB_WAIT_QUEUE_ENTRY *tail;	/* Queue tail. */
  DWB_WAIT_QUEUE_ENTRY *free_list;	/* Queue free list */

  int count;			/* Count queue elements. */
  int free_count;		/* Count free list elements. */
};
```

### DWB_WAIT_QUEUE_ENTRY
``` C
/* Queue entry. */
typedef struct double_write_wait_queue_entry DWB_WAIT_QUEUE_ENTRY;

struct double_write_wait_queue_entry
{
  void *data;			/* The data field. */
  DWB_WAIT_QUEUE_ENTRY *next;	/* The next queue entry field. */
};
```

### dwb_hashmap_type
``` C
using dwb_hashmap_type = cubthread::lockfree_hashmap<VPID, dwb_slots_hash_entry>;
```
Hash Map : Key, value 값으로 데이터가 저장된다.   
해싱(Hashing)검색을 사용하기 때문에 대용량 데이터 관리에 좋은 성능을 보인다.   
key : 중복을 허용하지 않음   
value : 중복 허용   

#### Hash
- 키(Key)값을 해쉬 함수(Hash Function)라는 수식에 대입하여 계산된 결과를 주소로 사용하여 바로 값(Value)에 접근하게 할 수 있는 방법

#### vdes
- fileio_format() 함수에서 npaes 의 Volume을 초기화하고 마운트 하여 반환하는 값
- Error 상황일때 NULL_VOLDES 값 저장

### file_sync_helper_block
- sync helper daemon 이 주기적으로 file_sync_helper()를 호출해서 DB로 Page를 flush.
- file_sync_helper_block 이 참조한 Block을 fsync 한 뒤, NULL로 초기화

### Volatile 변수
- 최적화 등 컴파일러의 역할을 제한하는 역할.
- 주로 최적화와 관련하여 volatile가 선언된 변수는 최적화에서 제외된다.
- OS와 연관되어 장치제어를 위한 주소체계에서 지정한 주소를 직접 액세스하는 방식을 지정할 수도 있다.
- 리눅스 커널 등의 OS에서 메모리 주소는 MMU와 연관 된 주소체계로 논리주소와 물리주소 간의 변환이 이루어진다. 경우에 따라 이런 변환을 제거하는 역할을 한다. 또한 원거리 메모리 점프 기계어 코드 등의 제한을 푼다.
