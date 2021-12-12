# 11. Disk Manager (4th Week)

## 1) Major Functions
```
disk_reserve_from_cache
│
├── disk_cache_lock_reserve_for_purpose
│   └── disk_cache_lock_reserve_for_purpose
│       └── disk_cache_lock_reserve_for_purpose
│
├── disk_cache_unlock_reserve_for_purpose
│   └── disk_cache_unlock_reserve_for_purpose
│       └── disk_cache_unlock_reserve_for_purpose
│
├── disk_reserve_from_cache_vols
│   └── disk_reserve_from_cache_volume
│       └── disk_cache_update_vol_free
│
├── disk_extend
│   ├── disk_volume_expand
│   └── disk_add_volume
│
├── disk_lock_extend
│
└── disk_unlock_extend
```

<br/>

## 2) disk_reserve_from_cache
### 1. Parameters
* THREAD_ENTRY * thread_p

	:	쓰레드 엔트리

* DISK_RESERVE_CONTEXT * context

	:	`disk_reserve_sectors` 함수에서 기록된 예약을 위한 맥락 (함수의 내용들을 수행하는 동안 구조체 내부 값이 변동될 수 있음, 아래와 같은 내용들이 있음)

		(1) 예약하려는 섹터 수 (`conext.nsect_total`)

		(2) 캐쉬로부터 예약이 완료되기 까지 남은 섹터 수 (`context.n_cache_reserve_remaining`)

		(3) 예약된 섹터의 id를 기록할 수 있는 공간 (`context.vsidp`)

		(4) 캐쉬로부터 예약을 진행한 섹터 수 (`context.n_cache_vol_reserve`)

		(5) 예약 대상이 되는 볼륨의 이용 목적 (`context.purpose`)

* bool * did_extend

	:	섹터 예약에 있어서 볼륨의 extend가 발생했는지 기록 (`disk_reserve_from_cache` 함수는 에러 코드를 반환하도록 되어 있으므로 추가적인 반환을 위해선 포인터 전달이 필요)

<br/>

### 2. Automatics
* DISK_EXTENDED_INFO * extend_info

	:	`disk_reserve_from_cache`는 TEMPORARY든 PERMANENT든 목적에 관계없이 캐쉬로부터 섹터 예약이 가능해야 하므로, (`context`에 기록된) 목적에 맞는 extend 정보들을 참조할 수 있도록 이용

* DKNSECTS save_remaining

	:	디스크의 extend를 위해 이용되는 `extend_info`의 `nsect_intention`을 조작하는데 사용되는 변수 (예약하려는 남은 섹터 수인 `context` 구조체 내부의 `n_cache_reserve_remaining`을 통해서 초기화 됨, extend 이전에 높인 `nsect_intention`을 extend 이후에 낮출 필요가 있는데 `n_cache_reserve_remaining`은 extend 과정에서 예약을 진행하면서 그 값이 변경되기 때문에 `save_remaining`에 예약이 필요한 남은 섹터수를 기록하게 됨)
