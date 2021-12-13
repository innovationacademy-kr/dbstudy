# 11. Disk Manager (4th Week)

## 1) Major Functions
```
disk_reserve_from_cache
│
├── disk_cache_lock_reserve_for_purpose
│   └── disk_cache_lock_reserve
│
├── disk_cache_unlock_reserve_for_purpose
│   └── disk_cache_unlock_reserve
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

## 2) disk_cache_lock_reserve_for_purpose & disk_cache_lock_reserve
### 1. Purpose
캐쉬로부터 섹터 예약을 진행하는 과정에서 볼륨의 목적에 맞는 LOCK을 취득하기 위한 함수
목적에 맞는 값을 `DB_VOLPURPOSE` 타입의 인자로 넘겨서 `disk_cache_lock_reserve` 함수를 호출

<br/>

### 2. Flows
(1) `me`라는 `int` 타입 변수에 `thread_get_current_entry_index`를 호출하여 자신의 쓰레드 엔트리 인덱스를 기록
```c
int me = thread_get_current_entry_index ();
```

<br/>

(2) `extend_info`의 `owner_reserve`는 LOCK을 취득하기 이전에는 -1로 되어 있다가, LOCK을 획득하면 그제서야 `me`로 기록해둔 값을 할당 (따라서 기존에 이미 `me`에 할당된 값이 존재하는 경우를 LOCK을 취득하기 이전에 검사)
```c
if (me == extend_info->owner_reserve)
{
	/* already owner */
	assert (false);
	return;
}
```

<br/>

(3) 쓰레드 엔트리 인덱스의 검증이 끝났다면, `pthread_mutex_lock` 함수 호출로 목적에 따른 LOCK을 취득
```c
pthread_mutex_lock (&extend_info->mutex_reserve);
```

<br/>

(4) LOCK이 취득되더라도 여전히 `owner_reserve`정보는 자신의 쓰레드 엔트리 값으로 바꾸지 않았기 때문에 -1인 상태므로 이에 대한 검증을 수행 후, `owner_reserve`값을 `me`로 할당
```c
assert (extend_info->owner_reserve == -1);
extend_info->owner_reserve = me;
```

<br/>

## 3) disk_cache_unlock_reserve_for_purpose & disk_cache_unlock_reserve
### 1. Purpose
캐쉬로부터 섹터 예약을 진행하는 과정에서 볼륨의 목적에 맞는 LOCK을 해제하기 위한 함수
목적에 맞는 값을 `DB_VOLPURPOSE` 타입의 인자로 넘겨서 `disk_cache_unlock_reserve` 함수를 호출

<br/>

### 2. Flows
(1) `thread_get_current_entry_index` 함수의 호출로 현재 쓰레드 엔트리를 `me`라는 변수에 할당
```c
int me = thread_get_current_entry_index ();
```

<br/>

(2) LOCK을 해제한다는 것은 기존에 취득한 LOCK을 놓겠다는 의미이고, LOCK을 획득했을 때는 `owner_reserve`에 me를 기록해두었기 떄문에 LOCK을 해제하기 이전에 LOCK을 소지하고 있는지 여부를 검증
```c
assert (me == extend_info->owner_reserve);
```

<br/>

(3) 검증을 마쳐서 LOCK을 소지하고 있던 것이 맞다면 `owner_reserve` 값을 다시 -1로 할당
```c
extend_info->owner_reserve = -1;
```

<br/>

(4) LOCK을 해제
```c
pthread_mutex_unlock (&extend_info->mutex_reserve);
```

<br/>

## 4) disk_lock_extend
### 1. Purpose
볼륨 extend를 수행하기 위해 LOCK을 획득하는 함수

<br/>

### 2. Flows
(1) `disk_cache_lock_reserve` 함수를 호출 했을 때와 마찬가지로 `thread_get_current_entry_index` 함수를 호출하여 쓰레드 엔트리를 `me`라는 변수에 할당
```c
int me = thread_get_current_entry_index ();
```

<br/>

(2) extend를 위한 LOCK을 잡기 전에는 목적에 따른 LOCK을 잡아두지 않은 상태여야 하므로 이에 대한 검증을 수행 (`me`와 `owner_reserve`가 달라야 함)
```c
assert (me != disk_Cache->perm_purpose_info.extend_info.owner_reserve);
assert (me != disk_Cache->temp_purpose_info.extend_info.owner_reserve);
```

<br/>

(3) `me`의 값이 전역 변수인 `disk_Cache`의 `owner_extend`와 같다면 이미 LOCK을 획득한 것이므로 그대로 함수 종료
```c
if (me == disk_Cache->owner_extend)
{
	/* already owner */
	assert (false);
	return;
}
```

<br/>

(4) LOCK 획득 후 `owner_extend`값에 `me`를 할당
```c
pthread_mutex_lock (&disk_Cache->mutex_extend);
assert (disk_Cache->owner_extend == -1);
disk_Cache->owner_extend = me;
```

<br/>

## 5) disk_unlock_extend
### 1. Purpose
볼륨 extend를 마치고 난 후 LOCK을 해제하는 함수

<br/>

### 2. Flows
(1) `me` 값을 `thread_get_current_entry_index`를 호출하여 할당
```c
int me = thread_get_current_entry_index ();
```

<br/>

(2) LOCK을 소유하고 있다면 `disk_Cache` 전역 변수의 `owner_extend` 값이 `me`와 같으므로 이에 대한 검증 시도
```c
assert (disk_Cache->owner_extend == me);
```

<br/>

(3) `owner_extend` 값을 -1로 되돌리고,  LOCK 해제
```c
pthread_mutex_unlock (&disk_Cache->mutex_extend);
```

<br/>

## 6) disk_reserve_from_cache
### 1. Parameters
```c
static int
disk_reserve_from_cache (THREAD_ENTRY * thread_p, DISK_RESERVE_CONTEXT * context, bool * did_extend)
```

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
```c
DISK_EXTEND_INFO *extend_info;
DKNSECTS save_remaining;
int error_code = NO_ERROR;
```

* DISK_EXTENDED_INFO * extend_info

	:	`disk_reserve_from_cache`는 TEMPORARY든 PERMANENT든 목적에 관계없이 캐쉬로부터 섹터 예약이 가능해야 하므로, (`context`에 기록된) 목적에 맞는 extend 정보들을 참조할 수 있도록 이용

* DKNSECTS save_remaining

	:	디스크의 extend를 위해 이용되는 `extend_info`의 `nsect_intention`을 조작하는데 사용되는 변수 (예약하려는 남은 섹터 수인 `context` 구조체 내부의 `n_cache_reserve_remaining`을 통해서 초기화 됨, extend 이전에 높인 `nsect_intention`을 extend 이후에 낮출 필요가 있는데 `n_cache_reserve_remaining`은 extend 과정에서 예약을 진행하면서 그 값이 변경되기 때문에 `save_remaining`에 예약이 필요한 남은 섹터수를 기록하게 됨)

* int error_code

	:	함수 내에서 특정 작업 수행 후, 에러 여부 기록 용도의 변수

<br/>

### 3. Flows
(1) 디스크 캐쉬가 초기화 되어 존재하고 있는지 확인
```c
if (disk_Cache == NULL)
{
	/* not initialized? */
	assert_release (false);
	return ER_FAILED;
}
```

<br/>

(2) 디스크 캐쉬를 조작하기 위해 목적에 따른 LOCK을 획득
```c
disk_cache_lock_reserve_for_purpose (context->purpose);
```

<br/>

(3) a. 목적이 TEMPORARY인 경우에는 VOLTYPE이 PERMANENT인 볼륨에서 먼저 예약 진행 (이 과정에서 단순하게 예약이 완료 되면 목적에 따른 LOCK을 해제하고 NO_ERROR 반환)

현재 예약이 되어 차지하고 있는 섹터 수 + 앞으로 예약이 필요한 섹터수가 VOLTYPE이 TEMPORARY인 볼륨의 섹터수보다 크거나 같다면, 목적에 따른 LOCK을 해제하고 공간 초과 에러를 반환 (만일 에러가 발생하지 않으면 그대로 분기문을 탈출)

이 때의 `extend_info`는 `&disk_Cache->temp_purpose_info.extend_info`가 됨
```c
if (context->purpose == DB_TEMPORARY_DATA_PURPOSE)
{
	/* if we want to allocate temporary files, we have two options: preallocated permanent volumes (but with the
	 * purpose of temporary files) or temporary volumes. try first the permanent volumes */

	extend_info = &disk_Cache->temp_purpose_info.extend_info;

	if (disk_Cache->temp_purpose_info.nsect_perm_free > 0)
	{
		 disk_reserve_from_cache_vols (DB_PERMANENT_VOLTYPE, context);
	}
	if (context->n_cache_reserve_remaining <= 0)
	{
		/* found enough sectors */
		assert (context->n_cache_reserve_remaining == 0);
		disk_cache_unlock_reserve_for_purpose (context->purpose);
		return NO_ERROR;
	}

	/* reserve sectors from temporary volumes */
	extend_info = &disk_Cache->temp_purpose_info.extend_info;
	if (extend_info->nsect_total - extend_info->nsect_free + context->n_cache_reserve_remaining >= disk_Temp_max_sects)
	{
		/* too much temporary space */
		assert (false);
		er_set (ER_ERROR_SEVERITY, ARG_FILE_LINE, ER_BO_MAXTEMP_SPACE_HAS_BEEN_EXCEEDED, 1, disk_Temp_max_sects);
		disk_cache_unlock_reserve_for_purpose (context->purpose);
		return ER_BO_MAXTEMP_SPACE_HAS_BEEN_EXCEEDED;
	}

	/* fall through */
}
```

<br/>

(3) b. 목적이 PERMANENT인 경우에는 VOLTYPE이 PERMANENT인 볼륨에서 바로 진행하면 됨

따라서 `extend_info`는 `&disk_Cache->perm_purpose_info.extend_info`가 됨
```c
else
{
	extend_info = &disk_Cache->perm_purpose_info.extend_info;
	/* fall through */
}
```

<br/>

(4) 목적이 TEMPORARY 라면 VOLTYPE == TEMPORARY, 목적이 PERMANENT 라면 VOLTYPE == PERMANENT 로 예약을 진행할 수 있게 됨

<br/>

(5) 예약을 진행해야 하는 섹터 수가 여전히 존재해야하고, 목적에 따른 LOCK이 여전히 걸려 있어야 추후 로직을 진행할 수 있음 (`extend_info` 구조체의 `owner_reserve`가 자기 자신의 쓰레드 엔트리 인덱스 값이어야 함)
```c
assert (context->n_cache_reserve_remaining > 0);
assert (extend_info->owner_reserve == thread_get_entry_index (thread_p));
```

<br/>

(6) a. 볼륨 내의 가용 공간 수가 예약하려는 섹터수보다 커서 예약 진행이 가능하다면, `disk_reserve_from_cache_vols`를 호출하여 예약을 진행 (이 때 예약하려는 섹터의 수가 0 이하 값이 된다면 예약을 무사히 진행한 것이므로, 목적에 따른 LOCK을 해제하고 NO_ERROR를 반환)

```c
if (extend_info->nsect_free > context->n_cache_reserve_remaining)
{
	disk_reserve_from_cache_vols (extend_info->voltype, context);
	if (context->n_cache_reserve_remaining <= 0)
	{
		/* found enough sectors */
		assert (context->n_cache_reserve_remaining == 0);
		disk_cache_unlock_reserve (extend_info);
		return NO_ERROR;
	}
}
```

<br/>

(6) b. 볼륨의 extend를 수행하여 예약을 진행해야하는 경우에는 extend 전용 LOCK을 획득해야 함

<br/>

(7) a. extend 전용 LOCK을 획득하는 과정에서 이미 다른 쓰레드 엔트리가 extend를 수행했을 수 있기 때문에, 다시 목적에 따른 LOCK을 획득하여 이를 판별

만일 이미 extend가 되어 있다면 굳이 현재 쓰레드 엔트리에서 extend를 수행할 필요가 없으므로, 섹터 예약 후에 목적에 따른 LOCK 해제 및 extend 전용 LOCK을 해제하고 NO_ERROR를 반환
```c
disk_cache_unlock_reserve (extend_info);

/* now lock expand */
disk_lock_extend ();

/* check again free sectors */
disk_cache_lock_reserve (extend_info);
if (extend_info->nsect_free > context->n_cache_reserve_remaining)
{
	/* somebody else expanded? try again to reserve */
	/* also update intention */
	extend_info->nsect_intention -= context->n_cache_reserve_remaining;

	disk_log ("disk_reserve_from_cache", "somebody else extended disk. try reserve from cache again. "
		"also decrement intention by %d to %d for %s.", context->n_cache_reserve_remaining,
		extend_info->nsect_intention, disk_type_to_string (extend_info->voltype));

	disk_reserve_from_cache_vols (extend_info->voltype, context);
	if (context->n_cache_reserve_remaining <= 0)
	{
		assert (context->n_cache_reserve_remaining == 0);
		disk_cache_unlock_reserve (extend_info);
		disk_unlock_extend ();
		return NO_ERROR;
	}

	extend_info->nsect_intention += context->n_cache_reserve_remaining;

	disk_log ("disk_reserve_from_cache", "could not reserve enough from cache. need to do extend. "
		"increment intention by %d to %d for %s.", context->n_cache_reserve_remaining,
		extend_info->nsect_intention, disk_type_to_string (extend_info->voltype));
}
```

<br/>

(7) b. 하지만 목적에 따른 LOCK을 획득 했을 때 extend가 진행되지 않았다는 것이 확인되면, 현재 쓰레드 엔트리에서 디스크 extend를 수행해야 하므로 목적에 따른 LOCK을 해제하고 `disk_extend` 함수를 호출하여 extend를 수행
```c
/* ok, we really have to extend the disk space ourselves */
save_remaining = context->n_cache_reserve_remaining;

disk_cache_unlock_reserve (extend_info);

error_code = disk_extend (thread_p, extend_info, context);
```

<br/>

(8) 디스크 extend가 완료되면 이에 대한 로그를 기록하기 위해 목적에 따른 LOCK을 잡고, 로그를 남긴 뒤에 해당 LOCK을 해제
```c
/* remove intention */
disk_cache_lock_reserve (extend_info);
extend_info->nsect_intention -= save_remaining;
disk_log ("disk_reserve_from_cache", "extend done. decrement intention by %d to %d for %s. \n",
	save_remaining, extend_info->nsect_intention, disk_type_to_string (extend_info->voltype));
disk_cache_unlock_reserve (extend_info);
```

<br/>

(9) 디스크 extend 과정에서 이미 섹터 예약이 모두 끝났고, 더 이상의 extend는 필요 없으므로 extend 전용 LOCK도해제
```c
disk_unlock_extend ();
```

<br/>

(10) 위 과정 동안 에러가 없었는지 확인하고, 예약하려는 섹터가 남았는지 확인

문제가 없다면 `did_extend`를 `true`로 만들고 NO_ERROR를 반환 (extend 되지 않고 정상적으로 예약이 되었다면 (3) a 혹은 (6) a에서 종료)
```c
if (error_code != NO_ERROR)
{
	ASSERT_ERROR ();
	return error_code;
}
if (context->n_cache_reserve_remaining > 0)
{
	assert_release (false);
	return ER_FAILED;
}

*did_extend = true;

/* all cache reservations were made */
return NO_ERROR;
```

<br/>

## 7) disk_reserve_from_cache_vols

<br/>

## 8) disk_reserve_from_cache_volume

<br/>

## 9) disk_cache_update_vol_free

<br/>

## 10) disk_extend

<br/>

## 11) disk_volume_expand

<br/>

## 12) disk_add_volume

<br/>

