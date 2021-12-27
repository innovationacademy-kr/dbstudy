# Disk Manager(6th Week)

# disk_extend() 함수 분석


## 1. 사전 맥락
---
 Disk Manager의 역할은 File Manager로부터 요청받은 섹터의 예약(사용)여부를 관리해주는 것이다. 섹터의 할당을 요청 받으면 Disk Manager는 섹터테이블(STAB)의 비트를 요청받은 섹터 수 만큼 켜줘서 예약을 진행한다. 이를 섹터 예약이라고 한다. (섹터테이블이란 각 섹터당 하나의 비트값으로 예약 여부를 관리하는 볼륨 내부의 메타 데이터 영역이다.)

 섹터 예약은 2단계로 이루어진다. (1)볼륨들의 합산 정보를 메모리에 Caching한 disk_Cache전역변수에 사전예약을 진행하고, (2)그 정보를 토대로 실제 볼륨 내부의 섹터테이블에 예약을 진행하는 방식이다. 1단계를 통해 속도가 빠른 메모리단에서 어떤 볼륨에 얼마나 예약을 진행할 지 결정하므로 효율적인 섹터 예약을 할 수 있다.

<img src="img/섹터 예약 순서도.png">

 이번 주 설명할 `disk_extend()`함수는 1단계인 사전예약 단계에서 실행되는 함수이다. 현재 생성되어 사용되는 볼륨만으로 요청된 섹터를 할당해줄 수 없을 때 볼륨을 확장, 추가해주는 작업을 수행한다. 볼륨의 확장(expand)이란 기존 볼륨의 용량을 늘리는 작업이고, 추가(add)는 새 볼륨을 생성하는 작업을 의미한다.
 > extend는 두 작업을 총칭하는 말로 여기서는 '확보'라고 표현하겠다.
 
 ## 2. 함수 구조
 ---
<img src="img/disk_extend_caller_graph.png">

```c
disk_reserve_sectors () //섹터 예약 진행
│
├── disk_reserve_from_cache ()//(1단계)사전 예약 진행
│   ├── disk_reserve_from_cache_vols ()
│   │	└── disk_reserve_from_cache_volume ()
│   │
│   └── disk_extend ()//기존 가용섹터로 예약 불가 시 섹터 확장을 위해 실행
│		  ├── disk_volume_expand ()//볼륨 확장
│		  ├── disk_reserve_from_cache_volume ()//그 볼륨에 사전예약 진행
│		  ├── disk_add_volume ()//볼륨 추가(새로운 볼륨 생성)
│		  └── disk_reserve_from_cache_volume ()
│
└── disk_reserve_sectors_in_volume ()//(2단계)실제 볼륨 STAB에 예약 진행
```

  `disk_extend()`함수의 흐름을 간략히 설명하면 다음과 같다.

1. **마지막 볼륨 확장(expand) 후 사전예약 진행함.**
2. **그래도 예약할 게 남았다면 새 볼륨 추가(add) 후 사전예약 진행**

 볼륨은 이 과정을 거쳐서 계속 추가되는 것이므로, 마지막 볼륨이 아닌 볼륨들은 항상 최대로 확장된 상태이다. 따라서 볼륨의 확장은 가장 마지막 볼륨만 시도하면 되는 것이다.

 이후 요청 섹터를 모두 사전예약할 때까지 '볼륨 추가 & 사전예약'을 반복한다.
<br>
<img src="img/expand_add.png">

 ## 3. 코드 분석
---
### 1) 변수 분석
<details>
<summary>1. 매개변수</summary>
<div markdown="1">

	'''c
	DISK_EXTEND_INFO * extend_info//타입 별 합산 정보 저장 구조체(disk_Cache에 속해있음)
	typedef struct disk_extend_info DISK_EXTEND_INFO;
	struct disk_extend_info
	{
	volatile DKNSECTS nsect_free;//볼륨들의 합산 가용 섹터 수
	volatile DKNSECTS nsect_total;//볼륨들의 합산 전체 섹터 수
	volatile DKNSECTS nsect_max;//모든 볼륨의 최대 확장 가능크기의 합
	volatile DKNSECTS nsect_intention;//확보하려는 섹터 수

	pthread_mutex_t mutex_reserve;//사전 예약 시 뮤텍스
	#if !defined (NDEBUG)
	volatile int owner_reserve;//뮤텍스 소유한 쓰레드id
	#endif				/* !NDEBUG */

	DKNSECTS nsect_vol_max;//볼륨 확장 시 최댓값, 볼륨 생성 시 볼륨 헤더의 nsect_max로 설정됨.
	VOLID volid_extend;//마지막에 생성된 volid, auto extent대상이 됨.
	DB_VOLTYPE voltype;//볼륨 타입
	};
	'''
	'''c
	DISK_RESERVE_CONTEXT * reserve_context//사전예약 관련 정보들 저장되어 있음.
	struct disk_reserve_context
	{
	int nsect_total; //예약 요청된 섹터 수
	VSID *vsidp; // 섹터의 배열, 예약과정에서 산출된 최종 섹터들의 위치

	DISK_CACHE_VOL_RESERVE cache_vol_reserve[VOLID_MAX]; // 볼륨별 사전예약 섹터 수의 배열
	int n_cache_vol_reserve; // 사전예약한 섹터들이 포함된 볼륨들의 수, cache_vol_reserve의 길이
	int n_cache_reserve_remaining; // 아직 사전예약 되지 못한 섹터들의 수, nsect_total - n_cache_vol_reserve = nsect_reserve

	DKNSECTS nsects_lastvol_remaining; //실제 예약 처리시에 해당 볼륨에서 남은 섹터 예약량

	DB_VOLPURPOSE purpose; // 예약 목적
	};
	'''
</div>
</details>
<details>
<summary>2. 지역변수 & 구조체</summary>
<div markdown="1">

	'''c
	DKNSECTS free = extend_info->nsect_free;//현재 가용 섹터
	DKNSECTS intention = extend_info->nsect_intention;//남은 요청 섹터 수
	DKNSECTS total = extend_info->nsect_total;//현재 섹터의 개수
	DKNSECTS max = extend_info->nsect_max;//확장 가능한 최대 섹터 개수
	DB_VOLTYPE voltype = extend_info->voltype;//확장 하려는 볼륨의 타입

	DKNSECTS nsect_extend;//확보해야 할 총 섹터수 저장
	DKNSECTS target_free;

	DBDEF_VOL_EXT_INFO volext;//볼륨 추가 시 필요한 정보 저장 구조체
	VOLID volid_new = NULL_VOLID;//새 볼륨 생성(add)시 이 변수에 id값 저장

	DKNSECTS nsect_free_new = 0;
	'''
	`DBDEF_VOL_EXT_INFO volext;` (지역변수)
	새 볼륨 추가(add)할 때 필요한 정보들을 저장한 구조체 변수이다.
	'''c
	typedef struct dbdef_vol_ext_info DBDEF_VOL_EXT_INFO;
	struct dbdef_vol_ext_info
	{
	const char *path; /*볼륨이 생성될 경로, NULL이면 시스템 파라미터 값 */
	const char *name;	/* 볼륨 명, NULL이면 [db_name].ext[volid] 형식으로 생성 */
	const char *comments;	/* Comments which are included in the volume extension header. */
	int max_npages; /* 생성하는 볼륨의 최대 페이지 */
	int extend_npages; /* Number of pages to extend - used for generic volume only */
	INT32 nsect_total; /* 생성 볼륨의 현재 섹터 수 */
	INT32 nsect_max; /* 볼륨이 확장할 때 가질 수 있는 최대 섹터 수 */
	int max_writesize_in_sec;	/* the amount of volume written per second */
	DB_VOLPURPOSE purpose;	/* The purpose of the volume extension. One of the following: -
					* DB_PERMANENT_DATA_PURPOSE, DB_TEMPORARY_DATA_PURPOSE */
	DB_VOLTYPE voltype;		/* Permanent of temporary volume type */
	bool overwrite;
	};
	'''
</div>
</details>

### 2) 함수 분석
<details>
<summary>1. 초기화(initialization)</summary>
<div markdown="1">

	```c
	DKNSECTS free = extend_info->nsect_free;//현재 가용 섹터
  	DKNSECTS intention = extend_info->nsect_intention;//남은 요청 섹터 수
  	DKNSECTS total = extend_info->nsect_total;//현재 섹터의 개수
  	DKNSECTS max = extend_info->nsect_max;//확장 가능한 최대 섹터 개수
  	DB_VOLTYPE voltype = extend_info->voltype;//확장 하려는 볼륨의 타입

  	DKNSECTS nsect_extend;//요청받은 섹터 총 개수 저장 변수
  	DKNSECTS target_free;

  	DBDEF_VOL_EXT_INFO volext;//볼륨 생성 시(add) 필요한 정보 저장 구조체
  	VOLID volid_new = NULL_VOLID;
    
    DKNSECTS nsect_free_new = 0;//확장, 추가로 얻은 가용섹터 수
    			.
    			.
    			.
    target_free = MAX ((DKNSECTS) (total * 0.01), DISK_MIN_VOLUME_SECTS);//??
    nsect_extend = MAX (target_free - free, 0) + intention;//확보해야 할 섹터 수 저장
    ```
</div>
</details>
<details>
<summary>2. 볼륨 확장(expand) & 사전예약</summary>
<div markdown="1">

	``` c

    if (total < max)
    {
    	DKNSECTS to_expand;

	 //2-1)현재 볼륨의 확장 섹터 수 구함.
    	to_expand = MIN (nsect_extend, max - total);
	 //2-2)볼륨 확장
    	error_code = disk_volume_expand (thread_p, extend_info->volid_extend,
		voltype, to_expand, &nsect_free_new);

    	assert (nsect_free_new >= to_expand);

		if (extend_info->nsect_total == extend_info->nsect_max)
		{
			extend_info->volid_extend = NULL_VOLID;
			//마지막 볼륨 확장했으므로, 확장할 볼륨 저장 변수에 NULL저장 
		}

     //2-3)확장된 섹터 수 변수들에 적용
      //확보할 총 섹터 수 저장 변수에 확장해서 새로 생긴 섹터수만큼 빼줌.
      nsect_extend -= nsect_free_new;

      //현재 총 섹터수를 의미하는 total변수에는 추가해줌.
      extend_info->nsect_total += nsect_free_new;
      //(total변수값 변경은 expand명령에서만 이루어지고 expand뮤텍스에 의해 보호됨.)
      //(expand 뮤텍스는 extend 함수 바깥에서 lock된 상태)

	 //2-4)확장한 볼륨에 사전예약 진행
    	disk_cache_lock_reserve (extend_info);//예약 뮤텍스 잠금
		//새로 생성한 섹터수를 disk_Cache-> extend_info안의 가용섹터수 저장 변수에 더해줌.
    	disk_cache_update_vol_free (extend_info->volid_extend, nsect_free_new);

		//예약할 섹터가 남았다면 예약 시도
    	if (reserve_context != NULL && reserve_context->n_cache_reserve_remaining > 0)
		{
	 		disk_reserve_from_cache_volume (extend_info->volid_extend, reserve_context);
		}
		disk_cache_unlock_reserve (extend_info);//예약 뮤텍스 해제

		//max만큼 확장 잘 됐는지 체크
    	assert (extend_info->nsect_total == extend_info->nsect_max);     
	```
</div>
</details>
<details>
<summary>3. 볼륨 추가(add) & 사전예약</summary>
<div markdown="1">

	''' c
	//3-1) volext지역변수 초기화.(볼륨 생성에 필요한 정보 저장하는 지역변수)
	volext.nsect_max = extend_info->nsect_vol_max;//볼륨 확장 시 최댓값
	volext.comments = "Automatic Volume Extension";
	volext.voltype = voltype;
	volext.purpose = voltype == DB_PERMANENT_VOLTYPE ? DB_PERMANENT_DATA_PURPOSE : DB_TEMPORARY_DATA_PURPOSE;
	volext.overwrite = false;
	volext.max_writesize_in_sec = 0;//1초당 얼마나 볼륨에 쓸 수 있는지(?)

	//3-2)사전예약 끝날 때까지 볼륨 추가&사전예약 반복
	while (nsect_extend > 0)
	{
		volext.path = NULL;
		volext.name = NULL;

	 //3-3)생성할 볼륨의 total값 저장
		volext.nsect_total = nsect_extend + DISK_SYS_NSECT_SIZE (volext.nsect_max);//???
		//유효범위에 맞게 조정
		//total이 max보다 크면 처음부터 max크기로 볼륨 생성(확장 불가)
		volext.nsect_total = MIN (volext.nsect_max, volext.nsect_total);
		volext.nsect_total = MAX (volext.nsect_total, DISK_MIN_VOLUME_SECTS);
		volext.nsect_total = DISK_SECTS_ROUND_UP (volext.nsect_total);
	 //3-4)볼륨 생성
		error_code = disk_add_volume (thread_p, &volext, &volid_new, &nsect_free_new);
		if (error_code != NO_ERROR)
		{
			ASSERT_ERROR ();
			return error_code;
		}
		assert (disk_Cache->nvols_perm + disk_Cache->nvols_temp <= LOG_MAX_DBVOLID);
	 //3-5)새로 볼륨 추가되서 생긴 섹터 수를 변수 값들에 적용
		nsect_extend -= nsect_free_new;

		extend_info->nsect_total += volext.nsect_total;
		extend_info->nsect_max += volext.nsect_max;
	 //3-6)추가한 볼륨에 사전예약 진행
		disk_cache_lock_reserve (extend_info);
		disk_Cache->vols[volid_new].nsect_free = nsect_free_new;
		assert (disk_Cache->vols[volid_new].purpose == volext.purpose);
		extend_info->nsect_free += nsect_free_new;
		if (reserve_context && reserve_context->n_cache_reserve_remaining > 0)
		{
		  disk_reserve_from_cache_volume (volid_new, reserve_context);
		  //생성한 볼륨에 사전예약 진행
		}

		disk_cache_unlock_reserve (extend_info);

		if (extend_info->nsect_total < extend_info->nsect_max)
		{
		    //사전예약이 끝난 경우, while문 탈출 전임.
			extend_info->volid_extend = volid_new;
		    //다음에 확장할 볼륨id 저장하는 변수에 새 볼륨id저장
		}

	    assert (disk_is_valid_volid (volid_new));//새 볼륨 id 범위 체크
	}
	'''
</div>
</details>