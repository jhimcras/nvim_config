# coderunner 이식 시나리오

원본: mdloom `before-lsp-scope` (`fc4d402072f191c9a3f73a8f2088a67244813975`).
2026-10-30에 태그의 테스트 본문과 assertions를 조사했다. 현재 checkout의 제거 진행과 무관하게 이 태그가 기준이다.
각 행은 원본 테스트 하나이며, 복합 테스트의 경계 입력도 입력/기대 칸에 포함한다.
대응 파일은 `tests/spec/coderunner/<이름>_spec.lua`; C1 이외 파일은 후속 구현 대상이다.
이 표는 **구현 완료 목록이 아니다**. 실제 단계 상태는 [계획서](coderunner_plan.md) 11절을 따른다.

## `crates/mdloom-core/tests/exec.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| document_content_never_becomes_arguments_or_shell | 셸 메타문자·중첩 토큰·빈 인자 | 플레이스홀더 치환 후 실행 | 인자 경계 유지, 재치환·셸 실행 없음 | command |
| stdin_env_and_cwd | UTF-8 stdin, env, 상대 cwd | runner/renderer 실행 | stdin·상속 PATH·env 전달, 기본/상대 cwd 정확 | exec, command |
| steps_stop_at_the_first_failure | 0→3→파일 생성 단계 | steps 실행 | 3에서 중단, 후속 파일 없음 | command |
| missing_tool_and_bad_cwd | 없는 실행 파일/2단계 도구/없는 cwd | 실행 | not_found와 spawn_failed 구분 | exec |
| timeout_kills_the_tree | 손자를 만드는 대기 도구 | 타임아웃 | 트리 종료, timeout 상태 | exec |
| cancel_kills_the_tree | 손자 PID를 기록하는 도구 | PID 확인 후 취소 | 트리 종료, cancelled, 슬롯 반환 | exec |
| leader_exit_cleans_up_descendants | 손자를 남기고 종료하는 리더 | 리더 정상 종료 | 남은 자손 종료, 파이프 대기 없음 | exec |
| large_output_is_drained_and_truncated | 두 스트림 4MiB, 경계/경계+1, 여러 단계 | 출력 수집 | 스트림별 상한·잘림, 단계 누적, 교착 없음 | exec |
| timeout_is_one_budget_for_all_steps | 600ms 단계 3개, 1500ms 예산 | steps 실행 | 3단계 도중 timeout, 앞 출력 보존 | command |
| timeout_starts_when_the_slot_is_acquired | 슬롯 1개, 앞 작업 800ms | 뒷 작업 대기 후 실행 | 대기는 예산에서 제외 | queue, exec |
| queue_is_fifo_and_cancellable_while_waiting | 슬롯 1개, 여러 작업 | 중간 대기 취소 | FIFO, 취소 작업 실행 안 함 | queue |
| max_jobs_change_applies_to_waiting_jobs | 진행·대기 작업 | 상한 변경 | 진행 유지, 대기는 새 상한 적용 | queue |
| timeouts_by_entry_kind | 항목별/전역 timeout | 각 종류 실행 | 항목→전역→30s 우선순위; 포맷터 제외 | command |
| renderer_output_and_format | svg/png, file/stdout | 렌더 명령 실행 | format/output 치환과 출력 획득 | command, render |
| missing_attribute_is_an_error | 없는 attr 토큰 | 실행 준비 | missing_attr, 어떤 단계도 실행 안 함 | command |
| tmpdir_and_file | ext 유무·본문·산출물 | 임시 입력 작성 | 전용 tmpdir/정확한 입력, 사용자 input.* 유지 | command |

## `crates/mdloom-core/tests/run.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| execution_targets_validate_hash_duplicate_id_and_output | 중복 ID/output/잘못된 해시/없는 키 | 블록 요청 | 거부 사유 구분, 현재 해시 허용 | run |

## `crates/mdloom-core/tests/render.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| render_keys_include_only_used_execution_context | 본문·포맷·블록 위치·docdir·명령/env/cwd 변경 | 키 계산 | 실제로 쓰는 컨텍스트만 키에 영향, 임시 경로 안정 | render |
| cache_hit_force_stale_and_failures | 같은 키/위치 이동/force/새 코드 실패 | 조회·렌더 | 현재 키 우선, force 동일 경로, stale, 실패 기록과 복구 | render |
| readonly_manifest_and_cancel_do_not_publish | 취소 전/렌더 도중 취소 | 결과 게시 | 취소 이미지·실패 미게시; 읽기 전용 manifest 모드는 CLI와 함께 제외 | render |
| concurrent_same_key_executes_once_and_different_keys_keep_manifest_entries | 동일 키 4개·다른 키 4개 | 동시 렌더 | 동일 키 1회 실행, manifest 항목 보존 | render, cache |
| command_renderer_reads_stdout_and_file_in_svg_and_png | stdout SVG/file PNG 도구 | 렌더 | 정확한 이미지 바이트·확장자 | render |
| gc_keeps_current_and_stale_references_and_skips_active_root | 현재 키/마지막 성공/고아/진행 작업 | dry-run·gc | 필요 이미지 보존, 진행 루트 건너뜀 | cache |
| gc_does_not_follow_diagrams_symlink | diagrams가 외부 symlink | gc | 거부, 외부 이미지 보존 | cache |
| cache_size_trims_oldest_images_and_preserves_disk_current_and_active_work | mtime 다른 이미지·디스크 현재·진행·stale | 용량 축소/무제한 | 오래된 비보호부터 삭제, 보호 초과 알림, unlimited 유지 | cache |

## `crates/mdloom-core/tests/export.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| new_export_copies_cache_and_retries_after_partial_failure | ID 블록·캐시 이미지 | 복사 성공/링크 실패 후 재시도 | stem-ID 파일, 동일 바이트 재사용·링크만 삽입 | export_apply |
| collisions_reuse_identical_bytes_even_after_a_gap | 빈 중간 번호와 동일 바이트 -3 파일 | 파일명 계획·실패 정리 | 동일 파일 먼저 재사용, 없으면 첫 빈 번호, 사본만 삭제 | export_plan, export_apply |
| adjacent_images_are_overwritten_and_stale_is_cache_dependent | 표준/wiki/HTML 인접 링크 | 내보내기·캐시 삭제 | 대상 갱신, 링크 유지, 캐시 없으면 stale 미판정 | export_plan, diagnostics |
| mismatch_missing_parent_and_duplicate_ids_are_rejected | 포맷 불일치·폴더 없음·중복 ID | 내보내기 준비 | 거부; 폴더 없음은 Q7 ask/never/always로 변경 | export_plan, export_apply |
| workspace_and_cache_symlink_escapes_are_rejected | 외부를 가리키는 첨부/캐시 symlink | 내보내기 준비 | 루트 이탈 거부, 외부 파일 보존 | export_plan, export_apply |
| configured_folders_and_container_insertions_preserve_blocks | 문서/루트 상대 폴더·인용·리스트·CRLF | 링크 삽입 후 재파싱 | 기존 블록/내용/접두사/줄 끝 보존 | export_plan |
| export_lease_prevents_gc_until_plan_is_dropped | 준비된 내보내기·동시 gc | 적용 중/완료 후 gc | 사용 중 사본 보호, 해제 후 수집 | cache, export_apply |
| attachment_config_accepts_relative_folder_and_rejects_escape | 상대 폴더/절대/역슬래시/독립 .. | 설정 검증 | 정상 상대 허용, 이탈 경로 거부 | config, export_plan |
| name_wiki_export_uses_resolver_targets_and_ambiguity | basename wiki·동명 다수·동일 폴더 우선·NFC/NFD | 대상 결정 | 첨부 폴더 직접 조회·모호성 거부(C7 결정, 아래) | export_plan |
| name_wiki_export_respects_collection_ignore_rules | ignore된 basename 이미지 | 대상 결정 | 원본 수집기 ignore 규칙 제외(C7 결정, 아래) | export_plan |
| default_attachment_api_uses_document_relative_assets | notes/note.md·기본 첨부 폴더 | 내보내기 | notes/assets 사용 | export_plan |

## `crates/mdloom-lsp/tests/run.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| run_uses_buffer_streams_and_keeps_jobs_in_the_requesting_session | 미저장 코드·오래된 해시·다른 연결 | 실행·출력 수집 | 버퍼 기준, 즉시 ID·스트리밍·완료; 연결 격리는 Neovim 인스턴스로 대체 | run |
| owner_cancel_and_disconnect_stop_children_and_release_slots | 진행 중 작업 | 취소·세션 종료 | 프로세스 종료·슬롯 반환; LSP 연결 수 검사는 제외 | run, exec |
| only_explicit_run_executes_and_failed_steps_truncate_output | 열기/저장/인덱싱·러너 없는 언어·실패 steps | 명시 실행 전후 비교 | 자동 runner 실행 없음, 거부와 잘림·종료 코드 보존 | run |
| response_precedes_output_and_release_enforces_ownership_and_io_errors | 사용자 input.svg·nested/input.sh·삭제 권한 실패 | 시작→해제→재해제 | 즉시 ID, 입력 자체만 제외, 삭제 실패 시 결과 보존; 소유권 RPC 제외 | run |
| waiting_cancel_has_full_empty_result_and_running_release_is_rejected | 슬롯 1개, 대기 작업 | 해제/취소 | 진행 해제 거부, 대기 취소는 경과 0·빈 출력·빈 파일 | run, queue |
| newest_oversize_result_is_kept_and_disconnected_artifacts_survive | 256MiB 초과 최신 결과 2개 | 완료·종료 | 최신 하나 유지·이전 정리·초과 알림, 종료 후 24h 보존 | run |
| connection_keeps_only_100_completed_results | 완료 결과 101개 | 보관·해제 | 첫 결과 정리, 나머지 100개 유지 | run |

## `crates/mdloom-lsp/tests/export.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| partial_move_retry_uses_existing_bytes_and_buffer_version | 열린 버퍼·이미지 이동 뒤 링크 실패 | 재시도 | 동일 이미지 재사용, 현재 버퍼 검증, 디스크 직접 편집 없음 | export_apply |
| move_failure_removes_copy_and_capabilities_gate_actions | 이미지 이동 실패·기능 미지원 클라이언트 | 내보내기 | 사본 정리; LSP capabilities/CodeLens 검사는 제외 | export_apply |
| export_all_partial_failure_reports_only_remaining_images | 기존 이미지 2개, 1개만 성공 | 일괄 갱신 | 성공 유지, 실패한 블록만 미적용 목록, 사본 정리 | export_apply |
| changed_disk_and_buffer_during_render_never_send_apply_edit | 느린 렌더 중 소스 변경 | 내보내기 완료 | 오래된 소스로 이미지/링크 수정 안 함 | export_apply |
| disconnect_after_apply_request_retains_copy_for_gc | 사본 준비 뒤 적용 응답 없는 연결 종료 | gc | 원본은 사본 lease; Lua 적용 중 이미지 보호로 대체, RPC 응답 수명 제외 | cache, export_apply |
| untrusted_batch_refuses_before_render_and_source_export_is_selective | 미신뢰 설정·기존 링크 | 일괄/단일 요청 | 일괄은 도구 실행 전 거부; codeAction 필터는 제외 | trust, export_apply |
| successful_batch_preserves_each_existing_image_format | 기존 PNG 링크·SVG 우선 렌더러 | 일괄 갱신 | 기존 PNG 유지, 임시 사본 정리 | export_apply |
| name_wiki_bulk_export_preserves_link_and_overwrites_resolver_target | basename wiki 링크·기존 assets 이미지 | 일괄 갱신 | 링크 유지·기존 이미지 갱신; basename 대상 결정은 아래 C7 규칙 | export_apply |

## `crates/mdloom/tests/execute.rs`

| 원본 테스트 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| run_selectors_streams_json_and_oneshot_modes | #id/언어:순번/없는 키·복수 블록 | 명시 실행 | 선택·stdout/stderr 검증; CLI JSON/oneshot/CI 모드 제외 | run |
| render_manifest_force_batch_trust_and_dry_run | 현재 키·force·미신뢰 일괄 | 렌더 | 캐시 재사용·강제 갱신·신뢰 거부; CLI dry-run/readonly 제외 | render, trust |
| export_single_links_image_bulk_preserves_doc_and_missing_target_recovers | 신규/기존/사라진 대상 링크 | 단일 생성·일괄 갱신 | 단일 링크 삽입, 일괄 링크 유지·대상 복구; CLI dry-run 제외 | export_apply |
| export_refuses_original_document_or_image_changed_during_render | 렌더 중 문서/기존 이미지 외부 변경 | 내보내기 | 외부 변경 보존, 오래된 결과 적용 거부 | export_apply |
| gc_current_references_export_copies_txn_and_vanished_roots | 현재 이미지·고아·사본·사라진 루트·끝 공백 루트 | gc/dry-run/all | 현재/진행 보호, 고아 삭제, 루트 검증; mdloom txn/index.db 제외 | cache |
| gc_refuses_child_symlinks_and_incomplete_scan | 하위 symlink/수집 실패 | gc | 삭제 거부, 외부/고아 파일 보존 | cache |
| daemon_cli_requests_share_job_queue | max_jobs=1, 두 요청 | 동시 요청 | 하나의 Neovim 큐에서 순차 실행; daemon 전송 제외 | queue |
| ctrl_c_cancels_child_tree_and_exits_130_in_both_modes | 손자가 있는 CLI 실행 | SIGINT | CodeCancel로 트리 종료에 대응; CLI 종료 코드 130 제외 | exec, run |
| daemon_cli_disconnect_stops_child_tree | 진행 요청의 연결 종료 | 종료 | Neovim 종료 시 트리 정리로 대체 | exec, run |
| gc_all_preserves_an_active_oneshot_render_after_root_disappears | 렌더 도중 workspace 삭제 | 다른 루트에서 gc all | 작업 중 보호, 완료 후 안전한 정리 | cache |
| export_open_buffer_force_and_independent_bulk_failures | 열린 버퍼·일괄 일부 렌더 실패 | 내보내기 | 버퍼 적용, 성공 이미지 유지·실패 이미지 보존; CLI 강제 디스크 쓰기 제외 | export_apply |
| daemon_cancel_frame_survives_streaming_between_fragments | 프레임 분할 도중 출력 | 취소 프레임 전송 | 제외: coderunner는 LSP/CLI 프레임을 사용하지 않음 | 제외 |
| name_wiki_export_reuses_resolved_asset_without_link_edits | basename wiki·기존 이미지 | 갱신 | 기존 대상 재사용·링크 보존; 대상 결정은 아래 C7 규칙 | export_apply |
| cli_artifacts_survive_command_and_start_failures_have_complete_json | 사용자 input.svg·없는 도구 | 실행 후 결과 확인 | 산출물 보존, 실패 결과 필드 완비; CLI JSON 포맷 제외 | run |

## Neovim 클라이언트 테스트

원본 Lua는 이름 있는 테스트 함수 대신 연속 assertions를 사용한다.

| 원본 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| execute_unit.lua: output replaces | 앞 문단 추가·기존 output·실패 stdout에 백틱 4개 | 결과 삽입 | 위치 이동 허용, 펜스 5개, .error, stderr 제외 | output_fence |
| execute_unit.lua: changed source/output | 소스 해시 또는 기존 output 변경 | 삽입 | 변경 영역 보존·거부 | output_fence |
| execute_unit.lua: first insertion | 인접 output 없음·뒤 문단 | 삽입 | 빈 줄 하나·stdout만·뒤 문단 보존 | output_fence |
| execute_unit.lua: output_lines | 빈 stdout | 펜스 작성 | 빈 output 펜스 2줄 | output_fence |
| execute_unit.lua: capabilities | 서버 기능 유무 | 명령 허용 | 제외: LSP 비의존 | 제외 |
| execute_unit.lua: early done/late chunks | 응답 전 완료·완료 후 출력 | 결과 갱신 | 최종 결과 보존·읽기 전용; client ID는 인스턴스로 대체 | run, result_view |
| execute_unit.lua: stale response | 오래된 해시 | 실행 | 거부·명시 재시도 안내; CodeLens refresh 제외 | run |
| execute_unit.lua: next run/release | 결과 버퍼 삭제·q·다음 실행·해제 실패/성공 | 다시 열기/해제 | q는 결과 유지, 다시 열기, 해제 실패 보존, 성공 폐기·빈 결과 안내; coderunner는 완료 결과 100개 보관 | result_view, run |
| execute_unit.lua: image bytes API | PNG·provider 교체·q | 이미지 열기 | 제외: rendermark 담당 | 제외 |
| execute_unit.lua: neopp | 경로·픽셀 배치·창 닫기·resize | 이미지 열기 | 제외: rendermark 담당 | 제외 |
| execute_unit.lua: image fallback | provider 없음/실패·없는 파일·SVG | 이미지 열기 | 제외: rendermark 담당 | 제외 |
| execute.lua: select/run | 코드 1개·stdout/stderr·지연 | 실행 | 즉시 작업 ID·스트리밍·readonly 결과 | run, result_view |
| execute.lua: opt-in output | 백틱 포함 stdout·연속 실행 | Run! 두 번 | 긴 펜스, 인접 결과 교체, output 순번 제외 | output_fence, blocks |
| execute.lua: source edits/failure | 실행 도중 소스 변경·실패 코드 7 | 완료 | 오래된 삽입 거부, 새 실패는 .error | output_fence |
| execute.lua: cancel | sleep 30 | 취소 명령 | cancelled·프로세스 종료 | run, exec |
| execute.lua: trust/untrust | 현재 workspace 설정 | 명시 로드·철회 | secure.read 허용/거부, 해시 변경 무효화 | trust |
| execute.lua: render/open/export | 가짜 SVG 렌더러·ID 블록 | 렌더·내보내기 | 경로·사본·링크 확인; 이미지 열기는 rendermark 담당 | render, export_apply |

## C1·C2 추가 원본

| 원본 | 입력 | 동작 | 기대·차이 | 대응 스펙 |
| --- | --- | --- | --- | --- |
| config.rs: command_entries | runner cmd/steps, renderer stdin/stdout·formats | 검증 | 필드·기본값 정확; formatter 제외 | config |
| config.rs: command_entry_errors | 누락/빈 배열/잘못된 타입·시간·cwd·env·formats·알 수 없는 키 | 검증 | 오류에 항목명, 잘못된 항목만 제외(원본 파일 단위 거부에서 변경), unknown 경고 | config |
| config.rs: renderer_attr_placeholder_is_an_error | cmd/steps/env/cwd의 attr 토큰·닫히지 않은 토큰 | 검증 | renderer attr 금지, runner 허용, 불완전 토큰 그대로 | config |
| config.rs: command_entries_replace_whole_and_keep_their_source | 같은 이름·다른 이름·전역/워크스페이스 | 병합/선택 | 항목 전체 교체·출처 보존·동일 출처 이름 순 | config |
| config.rs: exec_keys, m3_defaults_and_independent_render_settings | 시간/크기 경계·unlimited·개별 debounce | 검증 | 양수 정수+단위, overflow 거부, 30s/1MiB/512MiB/200ms 기본값 | config |
| trust.rs: status_trust_and_untrust, records_are_per_workspace_config_file | 파일 추가/변경/삭제·서로 다른 루트 | 상태·로드·철회 | 루트별 격리·해시 기반 무효화, Neovim 신뢰 DB 사용 | trust |
| trust.rs: record_files_are_atomic_and_fail_closed | 신뢰 파일 쓰기 오류 | 로드/철회 | DB 구현은 vim.secure에 위임, 오류 시 메모리 신뢰 제거 | trust |
| trust.rs: permission_table, untrusted_workspace_commands_are_blocked, global_commands_in_untrusted_workspaces | 출처×신뢰 상태×단일/일괄 | 허용 판정 | C1 표 준수, 설정 없는 루트는 허용, 미신뢰 전역 renderer 일괄 거부 | trust |
| trust.rs: replaced_names_never_fall_back_to_global | 같은 이름의 잘못된 workspace 항목 | 병합 | 낮은 우선순위 항목 복구 안 함; 미로드 파일은 아래 미결 참고 | config, trust |
| trust.rs: snapshot_uses_the_latest_bytes_and_rejects_config_errors | 승인/실행 중 내용 변경·문법/런타임 오류 | 로드 | 승인된 바이트만 평가, 다른 해시 캐시 금지, 오류 상태 | trust |
| trust.rs: skipped_formatter_warnings_once_per_config_and_hash | 미신뢰 formatter | 경고 | 제외: 외부 formatter 범위 밖 | 제외 |
| facts.rs: code_block_attributes, first_code_id_wins | Pandoc ID/class/quoted attr·잘못된 속성·여러 ID | 파싱 | 첫 ID·속성, 잘못된 속성은 무속성 | blocks |
| facts.rs: code_block_content_range_and_hash | 인용·들여쓰기·CRLF | 파싱 | 컨테이너 제거, 코드 들여쓰기 유지, 정규화된 hash | blocks |
| facts.rs: code_block_keys_skip_output_and_flag_duplicate_ids | 언어 순번·output·동일 ID | 키·중복 계산 | output 순번 제외, 중복 표시 | blocks |
| facts.rs: output_and_image_linking_by_blank_lines | output/표준/wiki/HTML, 빈 줄 0/1/2 | 연결 | 같은 컨테이너, 0/1만 연결 | blocks, export_plan |

## 조사에서 발견한 후속 결정

- **basename wiki 대상(C7 결정)**: 설정 첨부 폴더 바로 아래 svg/png만 조회하며 같은 stem 여러 대상은 거부한다. 확장자가 명시된 누락 파일은 같은 폴더의 복구 대상으로 쓴다. 경로 wiki는 문서 상대다. 원본의 workspace 수집·ignore·Unicode 정규화·동일 폴더 우선 검색은 LSP resolver 의존이므로 이식 범위에서 제외했다. `export_plan`/`export_apply`는 첨부 범위 조회·모호성·복구·링크 보존을 검증한다.
- **미로드 Lua의 이름 가리기(C4 확정)**: 신뢰 전 Lua를 실행해 항목 이름을 알아낼 수 없다. C1은 명시 resolve에서 secure.read를 거치며, 미로드 상태를 함께 반환한다. C3~C5의 명령 선택은 거부된 workspace 파일을 전역 항목으로 대체하지 않는 규칙을 지켜야 한다. 이름 가리기 금지를 우선해 workspace 파일이 있는데 미로드·거부·실패 상태면 단일 전역 실행도 거부한다. 전역 단일 허용은 파일이 없거나 로드된 상태에 적용한다. 공용 `trust.can_select(status)`를 서비스 진입 시 사용한다. 로드된 설정의 잘못된 같은 이름 항목은 `false` 표식으로 전역 복구를 막는다.
- **저장 후 편집**: C6의 구체 규칙(편집 시 취소하지 않고 닫기에서 취소)을 따른다. 원본 didChange 취소와 의도적인 차이다.
- **폴더 생성**: 원본 무조건 거부 대신 Q7의 ask/never/always를 따른다.
- **CLI/LSP 전용 기능**: JSON/RPC 프레임·소유권·capabilities·daemon·oneshot·transaction index는 구현하지 않는다. 프로세스 정리·부분 적용·경합·캐시 보호 의미는 위 대응 스펙에 남긴다.

C0 검증: 가짜 도구의 파일/stdin 반사·실패·대기·두 스트림 대량 출력·argv/env/cwd·파일 쓰기·손자 wait/exit 모드를 Linux에서 `tool_spec.lua`로 실행한다. C3 트리 종료 검증과 Windows 검증은 별개다.
