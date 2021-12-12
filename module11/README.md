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

* int error_code

	:	함수 내에서 특정 작업 수행 후, 에러 여부 기록 용도의 변수

<br/>

### 3. Flows

(1) 디스크 캐쉬가 초기화 되어 존재하고 있는지 확인

(2) 디스크 캐쉬를 조작하기 위해 목적에 따른 LOCK을 획득

(3) a. 목적이 TEMPORARY인 경우에는 VOLTYPE이 PERMANENT인 볼륨에서 먼저 예약 진행 (이 과정에서 단순하게 예약이 완료 되면 목적에 따른 LOCK을 해제하고 NO_ERROR 반환)

현재 예약이 되어 차지하고 있는 섹터 수 + 앞으로 예약이 필요한 섹터수가 VOLTYPE이 TEMPORARY인 볼륨의 섹터수보다 크거나 같다면, 목적에 따른 LOCK을 해제하고 공간 초과 에러를 반환 (만일 에러가 발생하지 않으면 그대로 분기문을 탈출)

이 때의 `extend_info`는 `&disk_Cache->temp_purpose_info.extend_info`가 됨

(3) b. 목적이 PERMANENT인 경우에는 VOLTYPE이 PERMANENT인 볼륨에서 바로 진행하면 됨

따라서 `extend_info`는 `&disk_Cache->perm_purpose_info.extend_info`가 됨

(4) 목적이 TEMPORARY 라면 VOLTYPE == TEMPORARY, 목적이 PERMANENT 라면 VOLTYPE == PERMANENT 로 예약을 진행할 수 있게 됨

(5) 예약을 진행해야 하는 섹터 수가 여전히 존재해야하고, 목적에 따른 LOCK이 여전히 걸려 있어야 추후 로직을 진행할 수 있음 (`extend_info` 구조체의 `owner_reserve`가 자기 자신의 쓰레드 엔트리 인덱스 값이어야 함)

(6) a. 볼륨 내의 가용 공간 수가 예약하려는 섹터수보다 커서 예약 진행이 가능하다면, `disk_reserve_from_cache_vols`를 호출하여 예약을 진행 (이 때 예약하려는 섹터의 수가 0 이하 값이 된다면 예약을 무사히 진행한 것이므로, 목적에 따른 LOCK을 해제하고 NO_ERROR를 반환)

(6) b. 볼륨의 extend를 수행하여 예약을 진행해야하는 경우에는 extend 전용 LOCK을 획득해야 함

(7) a. extend 전용 LOCK을 획득하는 과정에서 이미 다른 쓰레드 엔트리가 extend를 수행했을 수 있기 때문에, 다시 목적에 따른 LOCK을 획득하여 이를 판별

만일 이미 extend가 되어 있다면 굳이 현재 쓰레드 엔트리에서 extend를 수행할 필요가 없으므로, 섹터 예약 후에 목적에 따른 LOCK 해제 및 extend 전용 LOCK을 해제하고 NO_ERROR를 반환

(7) b. 하지만 목적에 따른 LOCK을 획득 했을 때 extend가 진행되지 않았다는 것이 확인되면, 현재 쓰레드 엔트리에서 디스크 extend를 수행해야 하므로 목적에 따른 LOCK을 해제하고 `disk_extend` 함수를 호출하여 extend를 수행

(8) 디스크 extend가 완료되면 이에 대한 로그를 기록하기 위해 목적에 따른 LOCK을 잡고, 로그를 남긴 뒤에 해당 LOCK을 해제

(9) 디스크 extend 과정에서 이미 섹터 예약이 모두 끝났고, 더 이상의 extend는 필요 없으므로 extend 전용 LOCK도해제

(10) 위 과정 동안 에러가 없었는지 확인하고, 예약하려는 섹터가 남았는지 확인

문제가 없다면 `did_extend`를 `true`로 만들고 NO_ERROR를 반환 (extend 되지 않고 정상적으로 예약이 되었다면 (3) a 혹은 (6) a에서 종료)
