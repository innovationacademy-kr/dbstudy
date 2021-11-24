# **DWB (Double Write Buffer)**

## **1. 개요**

DB 시스템은 Page Replacement를 위한 강제적 / 주기적 flush하는 작업을 진행한다.

Flush는 DWB를 사용하지 않고 진행하거나 DWB를 사용하여 진행할 수 있다.
* DWB를 사용하는 경우 system crash가 발생해서 일어난 partial write에 대해 page recovery가 가능
* 예) DWB에서 DWB volumn 혹은 DB로 page를 flush하는 도중 system crash가 발생하면 DB 페이지의 일부분(partial)만 write 일어남

DB 시스템이 DWB를 사용하는 방식
* Page를 저장할 공간 탐색 및 저장
* 특정 개수의 page를 disk로 한번에 flush
* partial write가 일어난 DB 복구

&nbsp;

## **2. DWB 구조**

이 문서에서 DWB라 함은 메모리에 할당되어 있는 DBW block들을 의미하며 block들은 slot들로 구성되어 있다.

DWB volumn은 disk에 저장되어 있는 DWB의 단일 블록이다.

Block은 매크로에서
* 개수 :  1개(`[DWB_MIN_BLOCKS]`) ~ 32개(`[DWB_MAX_BLOCKS`) 제한 (기본 2개)
* 크기 : 0.5M(`[DWB_MIN_SIZE]`) ~ 2M(`[DWB_MAX_SIZE]`) 제한 (기본 2M)

Slot의 총 개수는 기본적으로 256개이다.

**DWB**
* 전역변수
	* position_with_flags : 현재 page를 저장해야 할 block과 slot의 index, 현재 block 혹은 전체 DWB의 상태를 나타냄
	* file_sync_helper_block : daemon이 fsync를 주기적으로 호출할 때 사용하는 단일 block 포인터
* Block
	* 지역변수
		* write_buffer : 블록 내 모든 slot을 참조하여 실제 page 내용이 저장된 포인터
		* wait_queue : slot 탐색 중 대기가 일어나는 thread 저장
	* Slot
		* page를 관리하는 곳으로 page의 VPID, LSA 저장 가능
		* 해당 slot의 index와 몇 번째 block에 속하는지 알 수 있음

DWB volumn은 DB에 flush하려는 DWB block을 Disk에 먼저 flush한 block이다.

![DWB 구조](./module06_image/Structure_DWB.png)

&nbsp;

## **3. Slot 탐색 및 Page 저장**

* `dwb_acquire_next_slot()` : Slot의 위치 탐색 및 탐색 대기하는 함수
* `dwb_set_slot_data()` : Data Page를 저장하는 함수

DWB의 전역변수 `position_with_flags`를 비트 연산을 사용해서 block 및 slot의 index 탐색하여 slot의 시작주소 획득 (block의 index는 순환적)

→ 구한 slot의 index에 page 저장 (실제로는 block의 지역변수 write_buffer에 slot 순서대로 저장), VIPD, LSA 정보를 함께 저장

![slot 탐색 및 page 저장](./module06_image/slot_page.png)

### **3-1. 탐색 및 저장 실패 케이스**

Slot의 index를 찾기 전에 해당 block에 다른 thread가 write 작업을 진행 중일 때 나타나는 현상

> write 작업 : 다른 thread가 해당 block에 대해 slot 탐색 ~ DWB flush 사이의 작업 진행 중

Flush 순서 및 대기
1. Page를 저장해야 할 slot이 첫 번째 slot이고, Block이 다른 thread에 의해 writing 중인 상태
2. 해당 work thread를 대기 상태로 설정하려고 할 때 block의 지역변수에 존재하는 `wait_queue`에 work thread에 저장시키고 대기
3. 해당 block이 writing 상태가 끝날 때까지 work thread는 `dwb_acquire_next_slot()` 함수 내부 "start" goto phase부터 다시 진행
4. 해당 block에 대해 다른 thread가 write 작업을 마쳤다면, 다시 함수 내부에서 처음부터 시작할 때, 현재 thread가 전역변수 `position_with_flags`에서 현재 block의 상태를 writing으로 바꾼 다음 다시 slot의 index 찾기 작업 진행

#### 4. DWB Flush
- 하나의 Block의 slot이 page로 가득차면 Block의 Flush 시작.
1. DBW -> DWB volume
2. DWB -> DB Flush 순서로 진행된다.

#### DWB -> DWB volume Flush
- DWB를 사용해서 Disk로 Flush가 일어나는 경우
- System crash가 일어나기전 DWB Block -> DWB volume Flush 를 먼저 수행한다.
- Block의 지역변수 write_buffer을 사용하여 slot의 순서대로 DWB volume에 write를 진행
- Block 전체 Write가 끝나면, fsync()를 호출하여 DWB volume에 Flush 마무리

#### DWB -> DB Flush
- Block 내부의 slot들을 정렬 후, DB에 해당하는 Page마다 write() 진행
- 끝난 뒤 전역변수 file_sync_helper_block에 현재 Flush하려는 Block을 참조시킨다.
- Daemon을 호출해도 되는데, 그 이유는 이미 DWB Volume에 flush가 완료되었기 때문에, sysem crash가 발생하여도 recovery가 가능하기 때문.
- 각 Page마다 sync daemon을 호출하거나 불가능 하다면 fsync()를 직접 호출

#### Slot ordering
- Slot 정렬의 장점
  - DB에 있는 volume들이 VPID 순서로 정렬되어있다.
  - 같은 Page의 경우 Page LSA를 통해 최신 버전만 Flush 가능.
- Slot 정렬은 Slot행렬을 따로 만들서 Slot들을 복사 -> VPID, LSA 기준으로 정렬 후 이전 시점의 Page LSA를 가진 slot들은 초기화한다.

#### (Flush, Sync) daemon
- dwb flush block daemon
  - 주기적으로 Block의 모든 slot에 page가 저장되어있는지 (가득 찼는지) 확인한 후, 가득 찼다면 dwb_flush_block() 호출
- dwb file sync helper daemon
  - dwb flush block daemon이 호출하는 daemon
  - 주기적으로 dwb_file_sync_helper()를 호출하여 DB로 Page를 flush
  - file_sync_helper_block이 참조한 Block을 fsync() 한뒤, NULL로 초기화
  
### 5. Corrupted Data Page Recovery
위 문서에서 `Page Corrupted` 라는 뜻은 DB의 논리적인 Page를 Write 할 때 Partial Write가 일어난 Page를 뜻한다.
Partial Write란 논리적 Page를 디스크 Page로 저장하는 과정에서 일부를 저장하지 못하는 경우를 말한다.
또한 log를 통해 이뤄지는 recovery는 데이터 자체의 recovery이므로 DWB를 통해 이뤄지는 recovery와는 관련 없는 내용을 밝힌다. 정확히는 log recovery를 진행하기 전에 실행한다.
Recovery가 시작되면, corruption test를 진행하여서 recovery를 진행할 Page를 선별하고 recovery가 불가능한 경우에는 recovery를 그대로 종료한다.
Recovery가 시작할 때 recovery block이 만들어지며 DWB volume에 저장된 내용을 메모리에 할당시킨다. 할당된 Block은 slot ordering 을 통해서 정렬시킨 뒤, 같은 Page의 최신 Page LSA(Log Sequence Address)를 가진 Page만 Recovery에 사용된다.
dwb_check_data_page_is_sane() 함수를 통해 corruption test를 진행하고, dwb_load_and_recover_pages() 함수를 통해 전체적인 recovery를 진행한다.
#### 5.1 Corruption Test
같은 volume fd, page id를 가진 recovery block의 Page와, DB의 Page의 corruption test를 각각 진행한다.
LSA(Log Sequence Address)를 통해서 Partial Write이 일어났는지 확인한다.
Recovery block에서 corruption이 발생했다면, recovery를 잘못된 data로 진행하는 것이 되기 때문에 recovery를 중지한다.
Recovery block에서 corruption이 발생하지 않았다면, 해당 page는 recovery에 사용가능하다.
DB Page가 corruption이 발생했다면, 그 다음 Page의 corruption test를 진행한다.
DB Page가 corruption이 발생하지 않았다면, 해당 slot은 NULL로 초기화 시켜서 recovery 속도를 향상시킬 수 있게 한다.
#### 5.2 Recovery
정렬된 Recovery block을 DB에 Flush를 진행한다.
`4.1.2`에서 DWB block을 DB에 write하는 방식처럼 slot을 정렬한 뒤 write을 진행한다. Write을 진행한 다음 곧바로 Page에 대해서 Flush를 진행한다.
### 6. Appendix
DWB 자체의 역할보다는 DB 시스템에서 부수적으로 사용되는 DWB의 역할에 대해서 알아보려고 한다.
#### Slot Hash Entry
Page replacement에서 Cache 역할을 담당.
Memory에 찾으려는 Page가 없다면, DWB에서 찾는다. (Disk가 아닌 DWB에서 Page를 가져와 I/O cost 감소)
생성 시점 : add_page() 함수에서 block과 slot의 index를 구한 다음 생성
제거 시점 : DB에 Flush 마치고 제거한다.
Key, Value값으로서 저장

#### Flush
일반적으로 Memory에 있는 Data를 Disk에 쓰고 동기화 하는 행위

#### Buffer Pool
메인 메모리 내에서 데이터와 인덱스 데이터가 접근될 떄, 해당 데이터를 캐시하는 영역이다.   
자주 접근되는 데이터를 메모리에서 바로 흭득 가능하다.   
-> 전체 작업의 수행속도 증가.
대량의 읽기 요청 수행을 위해 Buffer Pool은 데이터를 Page단위로 나누어 관리한다.
한 Page에는 여러 row가 존재할 수 있다.
- Mysql의 경우
Buffer Pool 내부의 Page는 Linked-List로 관리한다.
새로운 페이지를 Buffer Pool에 추가하기 위한 페이지 공간이 필요한 경우, 일종의 LRU 알고리즘 (Least Recently Used)을 사용하여 관리한다.

#### Double Write Buffer 파일
- DWB 파일은 Partial Write로 인한 I/O 에러를 방지하기 위한 저장공간이다.
- 모든 데이터 페이지는 DWB에 먼저 쓰여지고 난 후 영구 데이터 볼륨에 있는 데이터 위치에 쓰여진다.
- DB가 재시작할때, 부분적으로 쓰여진 페이지들이 탐지되고, DWB에서 대응되는 페이지로 대체된다.
- DWB 파일 크기는 cubrid.conf의 double_write_buffer_size에 의해 결정. 0으로 설정시 DWB을 사용하지 않고, 파일도 생성되지 않는다.
- `testdb_dwb`

#### fsync()
- 프로세스가 파일에 쓰기 작업을 요청하면 운영체제가 요청을 수행한다.
- 시스템에서 효율을 위해 쓰기 요청을 버퍼에 기록해두었다가 처리한다면?
  - 쓰기 요청한 시간 != 실제 디스크에 쓰여지는 시간
- fsync() -> kernel에 저장된 buffer를 무조건 disk에 write 하게 하는 함수이다.
- data, file의 meta data 를 함께 동기화한다.
  ```c
  #include <unistd.h>
  int	fysnc(int fd);
  ```
- fd : file descriptor, 반드시 쓰기(O_WRONLY, O_RDWR)로 열려야 한다.

#### Vpid LSA
  - Volume PID ?
  - Page LSA ?
=======