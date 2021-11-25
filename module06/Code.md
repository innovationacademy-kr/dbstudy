## 진입점

```cpp
dwb_create (thread_p, log_path, log_prefix)
=> boot_create_all_volumes
=> xboot_initialize_server
=> boot_initialize_server
=> boot_initialize_client
=> db_init
=> createdb
```

<br/>

## dwb_create

*storage/double_write_buffer.c: 2820*

```cpp
/*
 * dwb_create () - Create DWB.
 *
 * return   : Error code.
 * thread_p (in): The thread entry.
 * dwb_path_p (in) : The double write buffer volume path.
 * db_name_p (in) : The database name.
 */
int dwb_create(THREAD_ENTRY *thread_p, const char *dwb_path_p, const char *db_name_p)
{
  UINT64 current_position_with_flags;
  int error_code = NO_ERROR;

  error_code = dwb_starts_structure_modification(thread_p, &current_position_with_flags);
  if (error_code != NO_ERROR)
  {
    dwb_log_error("Can't create DWB: error = %d\n", error_code);
    return error_code;
  }

  /* DWB structure modification started, no other transaction can modify the global position with flags */
  if (DWB_IS_CREATED(current_position_with_flags))
  {
    /* Already created, restore the modification flag. */
    goto end;
  }

  fileio_make_dwb_name(dwb_Volume_name, dwb_path_p, db_name_p);

  error_code = dwb_create_internal(thread_p, dwb_Volume_name, &current_position_with_flags);
  if (error_code != NO_ERROR)
  {
    dwb_log_error("Can't create DWB: error = %d\n", error_code);
    goto end;
  }

end:
  /* Ends the modification, allowing to others to modify global position with flags. */
  dwb_ends_structure_modification(thread_p, current_position_with_flags);

  return error_code;
}
```
