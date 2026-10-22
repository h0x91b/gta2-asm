; debug_emergency.asm — "Call ambulance" and "Call fire truck" on the debug menu's Player
; page (K). Neither spawns a vehicle itself: each hands the game the trigger its own
; emergency services react to, so the dispatch, the vehicle, the siren, the crew and its
; AI are all the game's (docs/re/gangs-and-peds.md section 7, verified in Ghidra):
;
; - Ambulance. The only trigger is a corpse in g_AmbulanceManager's queue. The nearest
;   body within DE_RANGE (on foot, with a sprite, no group, not player / special AI /
;   mission class, not queued yet: objective not 28 or 50) gets PedSetObjective(28),
;   whose case 28 is AmbulanceManager_EnqueuePed. With no body, the nearest such live ped
;   is killed with Ped_OnDeath, as the mission opcode KILL_CHAR does (0x47E130); its own
;   death path sets objective 28 (0x441306). Nobody is picked without a road tile near
;   them (de_road_near_ped), and a body the game drops is queued again (de_amb_requeue).
;   AmbulanceManager_DispatchForQueuedPed 0x473E00 then takes a road tile near the body,
;   waits 300 ticks and the MEDICAR comes; the paramedics revive the ped.
; - Fire truck. Car_RequestFireTruckAndSpawnFlames 0x41F9F0 (fastcall ecx = car, no
;   stack args; the wreck path Car_BecomeWreck calls it) asks FireEngineManager for a
;   truck and, if a slot was granted, attaches a fire object to the car. That flame is
;   what FireEngineSlot_UpdateWatchdog 0x450CD0 checks while the crew hoses. The target
;   stands in for the native wreck: a driverless car in the middle of a lane (not on a
;   junction, de_lane_tile) within DE_FIRE_RANGE, nearest first, until the game grants a
;   truck for one; else a car of the Vehicle page's model is put mid-lane on the nearest
;   lane (de_spawn_on_road). The game refuses a car without a road tile at least 2 lanes
;   wide near it (FireEngineManager_AllocRequest 0x451300) or with both truck slots busy.
;
; Known limit, found in the Seq 43 bug hunt (2026-10-22): the game's own FollowRoute never
; steers a service car into the target's lane nor arrives (z gate at 0x430444, see
; hk_FollowRoute below), so without the hook the vehicle drives past the target one lane
; over. hk_FollowRoute makes the two services arrive after a call; the cause is in the
; game's code, not in the port.
;
; Both honour the game's own switches g_skipAmbulance 0x5EAD6B / g_skipFireEngines
; 0x5EAD8B. After a call the slot states are printed to stdout every DE_LOG_EVERY frames
; for DE_LOG_FRAMES frames in a NASMFLAGS=-DDE_TRACE build (player, slots, the truck's
; route); every build prints an "emerg:" line per call and per slot state change.
;
; Addresses: re/functions.csv, re/globals.csv and own decompiler reading in
; gta-2-recovered (2026-10-21); PedSetObjective 0x43BBC0 fastcall(Ped*, edx; objective,
; timer), ret 8, from gta2-seuko-mod by izawartka
; (https://github.com/izawartka/gta2-seuko-mod), src/game/functions.h @25b1985.
; Struct offsets: re/gta2_types.h (Ped, AmbulanceManager, AmbulanceSlot,
; EmergencyVehicleSlot, FireEngineManager, FireEngineSlot).

DE_RANGE        equ 10 << 14        ; Chebyshev, 10 blocks (SCR_f)
DE_LOG_FRAMES   equ 1800
DE_LOG_EVERY    equ 20
DE_PED_GROUP    equ 0x164
DE_PED_CLASS    equ 0x238
DE_PED_OBJ      equ 0x258
DE_PED_STATE    equ 0x278
DE_STATE_WASTED equ 9               ; Ped_IsWasted 0x403B60: state == 9
DE_OBJ_AMBULANCE equ 28             ; PED_OBJECTIVE_UNKNOWN_28: queue for an ambulance
DE_OBJ_REMOVE   equ 50              ; PED_OBJECTIVE_UNKNOWN_50: body removed, no ambulance
AMBULANCE_MGR   equ 0x663DE4        ; AmbulanceManager*: +1 pendingCount, +0xD0 slots[2] x 0x20
FIREENGINE_MGR  equ 0x5EA9CC        ; FireEngineManager*: slots[2] x 0x28
SKIP_AMBULANCE  equ 0x5EAD6B
SKIP_FIREENGINES equ 0x5EAD8B
CAR_POOL        equ 0x5E4CA0        ; CarPool*
ROAD_NETWORK    equ 0x5D351C        ; g_RoadNetwork
DE_ROAD_RINGS   equ 16
PED_PATHFINDER  equ 0x66A7E4        ; g_PedPathfinder
MAP_BLOCKS      equ 0x662C08        ; g_MapBlocks
DE_FIRE_RANGE   equ 16 << 14        ; cars tried for a fire truck, Chebyshev
DE_TRIES        equ 8
DE_AMB_RETRIES  equ 30

section .text

dm_ambulance_change:
    test esi, esi
    jnz .out
    mov byte [de_req], 1
.out:
    ret

dm_firetruck_change:
    test esi, esi
    jnz .out
    mov byte [de_req], 2
.out:
    ret

dm_ambulance_fmt:
dm_firetruck_fmt:
    mov byte [rdi], 0
    ret

; hk_FollowRoute: CALLHOOK at 0x432678, the `call CarAI_FollowRoute` (0x430320, fastcall
; ecx = CarAI*) in CarAI_Update. Why (measured, Seq 43 bug hunt, docs/re/cars-and-car-ai.md):
; FollowRoute only steers into the target's lane and only arrives by "passed the target
; along the segment" when floor(car z - 1.0) == floor(order z) (0x430437..0x430444), but
; every drive order the game gives its services carries the SPRITE z of the ground (2.0:
; FindSpawnRoadTile node z for the ambulance, the wreck's z for the fire truck, script
; goto_area_in_car z=2.0), while a car on flat ground has z 2.0 too, so floor(z - 1) = 1
; != 2 and the services drive past a target one lane over forever. For the car an
; AmbulanceManager / FireEngineManager slot holds (de_is_service_car), after a K-menu
; call, the order's z is set to car z - 1.0 for the length of the call only (CarAI_UpdateDriveOrder 0x42d390 plans with the sprite z, so the order
; must keep it between calls).
hk_FollowRoute:
    HENTER
    mov r12d, [abs G_ECX]           ; CarAI*
    xor r13d, r13d                  ; order whose z was changed
    cmp byte [de_assist], 0
    je .call
    mov edi, [r12]                  ; Car*
    call de_is_service_car
    test eax, eax
    jz .call
    mov eax, [r12]
    mov r13d, [rax + 0x60]          ; CarDriveOrder*
    test r13d, r13d
    jz .call
    mov ecx, [rax + 0x50]           ; body (Sprite)
    mov r14d, [r13 + 0x1c]          ; the order's z
    mov ecx, [rcx + 0x1c]
    sub ecx, 0x4000
    mov [r13 + 0x1c], ecx
.call:
    mov edi, 0x430320
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    mov r8d, r12d
    xor r9d, r9d
    call call32
    test r13d, r13d
    jz .out
    mov eax, [r12]
    cmp [rax + 0x60], r13d          ; still the same order
    jne .out
    mov [r13 + 0x1c], r14d
.out:
    HRET

; eax = de_is_service_car(edi = Car*): 1 if the car is the vehicle of an active
; AmbulanceSlot (AMBULANCE_MGR +0xD0 slots[2] x 0x20: +4 EmergencyVehicleSlot*, whose +0
; is the car; +0x18 slot state) or the truck of an active FireEngineSlot (FIREENGINE_MGR
; slots[2] x 0x28: +4 active, +0x1c truck); same fields as de_log_changes
de_is_service_car:
    xor eax, eax
    test edi, edi
    jz .out
    mov ecx, [abs AMBULANCE_MGR]
    test ecx, ecx
    jz .fire
    xor edx, edx
.a:
    mov r8d, edx
    shl r8d, 5
    cmp dword [rcx + 0xD0 + r8 + 0x18], 0
    je .an
    mov r9d, [rcx + 0xD0 + r8 + 4]
    test r9d, r9d
    jz .an
    cmp [r9], edi
    je .yes
.an:
    inc edx
    cmp edx, 2
    jb .a
.fire:
    mov ecx, [abs FIREENGINE_MGR]
    test ecx, ecx
    jz .out
    xor edx, edx
.f:
    imul r8d, edx, 0x28
    cmp dword [rcx + r8 + 4], 0
    je .fn
    cmp [rcx + r8 + 0x1c], edi
    je .yes
.fn:
    inc edx
    cmp edx, 2
    jb .f
    jmp .out
.yes:
    mov eax, 1
.out:
    ret

; de_run (DM_FRAME): once per gameplay frame from hk_DrawUI, on the game's side
de_run:
    sub rsp, 8
%ifdef DE_TEST_TP
    ; test only (-DDE_TEST_TP=frame -DDE_TEST_TX=x -DDE_TEST_TY=y; the Downtown start square has
    ; no road within the 6 rings the ambulance search needs): at frame DE_TEST_TP the player is moved to tile (DE_TEST_TX, DE_TEST_TY)
    ; by Ped_Teleport 0x435C80 fastcall(Ped*, edx; SCR_f x, y), ret 8 (as debug_roads.asm DR_TEST)
    cmp dword [r_frames], DE_TEST_TP
    jne .notp
    call dm_player_ped
    test eax, eax
    jz .notp
    mov dword [de_args], (DE_TEST_TX << 14) | 0x2000
    mov dword [de_args + 4], (DE_TEST_TY << 14) | 0x2000
    mov r8d, eax
    mov edi, 0x435C80
    lea rsi, [de_args]
    mov edx, 2
    xor ecx, ecx
    xor r9d, r9d
    call call32
.notp:
%endif
    movzx eax, byte [de_req]
    mov byte [de_req], 0
    test eax, eax
    jz .nocall
    mov byte [de_assist], 1         ; from the first call on, hk_FollowRoute helps
%ifdef DE_TRACE
    ; CRT static-initialiser constants the route code reads (re/static_constants.csv)
    lea rdi, [fmt_de_consts]
    mov esi, [abs 0x5E512C]         ; 1.0  = 0x4000
    mov edx, [abs 0x5E50B8]         ; 5.0  = 0x14000
    mov ecx, [abs 0x5E520C]         ; 2.0  = 0x8000
    mov r8d, [abs 0x5E5398]         ; 0x1eb
    push rax
    push rax
    xor eax, eax
    call _printf
    pop rax
    pop rax
%endif
.nocall:
    cmp eax, 1
    jne .f
    call de_call_ambulance
    jmp .log
.f:
    cmp eax, 2
    jne .log
    call de_call_firetruck
.log:
    call de_amb_requeue
%ifdef DE_TRACE
    call de_log
%endif
    call de_log_changes
    add rsp, 8
    ret

; de_log_changes: an "emerg: ... ->" line whenever a FireEngineSlot state or an
; ambulance's EmergencyVehicleSlot stage changes (always on: a few lines per call)
de_log_changes:
    push rbx
    push r12
    push r13
    mov ebx, [abs FIREENGINE_MGR]
    test ebx, ebx
    jz .amb
    xor r12d, r12d
.f:
    imul eax, r12d, 0x28
    mov edx, [rbx + rax + 8]        ; state
    cmp dword [rbx + rax + 4], 0
    jne .fa
    xor edx, edx
.fa:
    lea rcx, [de_prev]
    cmp [rcx + r12*4], edx
    je .fn
    mov r13d, [rcx + r12*4]
    mov [rcx + r12*4], edx
    mov edi, [rbx + rax + 0x1c]     ; truck
    push rdx
    push rdx
    call de_carpos
    pop rdx
    pop rdx
    lea rdi, [fmt_de_chg_fire]
    mov esi, [r_frames]
    mov ecx, edx
    mov edx, r12d
    mov r9d, eax
    mov r8d, r13d
    mov eax, [dm_last_car]
    mov r10d, -1
    test eax, eax
    jz .fl
    mov r10d, [rax + 0x88]          ; lifeState of the last car we spawned
.fl:
    xor eax, eax
    sub rsp, 8
    push r10
    call _printf
    add rsp, 16
.fn:
    inc r12d
    cmp r12d, 2
    jb .f
.amb:
    mov ebx, [abs AMBULANCE_MGR]
    test ebx, ebx
    jz .out
    xor r12d, r12d
.a:
    mov eax, r12d
    shl eax, 5
    mov edx, -1
    cmp dword [rbx + 0xD0 + rax + 0x18], 0
    je .aa
    mov ecx, [rbx + 0xD0 + rax + 4]
    test ecx, ecx
    jz .aa
    mov edx, [rcx + 0x28]           ; stage
.aa:
    lea rcx, [de_prev + 8]
    cmp [rcx + r12*4], edx
    je .an
    mov r13d, [rcx + r12*4]
    mov [rcx + r12*4], edx
    lea rdi, [fmt_de_chg_amb]
    mov esi, [r_frames]
    mov ecx, edx
    mov edx, r12d
    mov r8d, r13d
    xor eax, eax
    call _printf
.an:
    inc r12d
    cmp r12d, 2
    jb .a
.out:
    pop r13
    pop r12
    pop rbx
    ret

; de_amb_requeue: for DE_AMB_RETRIES frames after a call, queue the body again when the
; game has dropped it. AmbulanceManager_DispatchForQueuedPed pops the body and gives up
; without a road tile, and its unsure_Map_FindSpawnRoadTile refuses outright while
; PedPathfinder +0x38 is set, which flips every frame (measured: 1, 0, 1, ...). The
; give-up sets objective 50, which PedSetObjective ignores on a dead ped, so the body
; just lies there with objective 28 and no ambulance (measured, 2026-10-21). Dropped =
; queue empty and no AmbulanceSlot active; done as soon as one is.
de_amb_requeue:
    push rbx
    mov eax, [de_amb_retry]
    test eax, eax
    jz .out
    dec eax
    mov [de_amb_retry], eax
    mov ebx, [de_amb_ped]
    test ebx, ebx
    jz .stop
    cmp dword [rbx + DE_PED_STATE], DE_STATE_WASTED
    jne .stop
    mov ecx, [abs AMBULANCE_MGR]
    test ecx, ecx
    jz .stop
    cmp dword [rcx + 0xD0 + 0x18], 0
    jne .stop                       ; an ambulance is on it
    cmp dword [rcx + 0xD0 + 0x20 + 0x18], 0
    jne .stop
    cmp byte [rcx + 1], 0           ; still queued: the game has not looked yet
    jne .out
    mov dword [de_args], DE_OBJ_AMBULANCE
    mov dword [de_args + 4], 9999
    mov edi, 0x43BBC0               ; PedSetObjective(body, 28, 9999): queue it again
    lea rsi, [de_args]
    mov edx, 2
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
    lea rdi, [fmt_de_requeue]
    mov esi, [r_frames]
    xor eax, eax
    call _printf
    jmp .out
.stop:
    mov dword [de_amb_retry], 0
.out:
    pop rbx
    ret

; eax = Chebyshev distance between SCR_f points (ecx, edx) and (r8d, r9d)
de_dist:
    mov eax, ecx
    sub eax, r8d
    mov ecx, eax
    neg ecx
    cmovns eax, ecx
    sub edx, r9d
    mov ecx, edx
    neg ecx
    cmovns edx, ecx
    cmp eax, edx
    cmovl eax, edx
    ret

de_call_ambulance:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    mov r14d, eax
    lea r13, [s_de_skipamb]
    cmp byte [abs SKIP_AMBULANCE], 0
    jne .toast
    mov dword [rsp], DE_RANGE + 1   ; best live distance
    mov dword [rsp + 4], 0          ; best live ped
    mov dword [rsp + 8], DE_RANGE + 1 ; best body distance
    xor r12d, r12d                  ; best body
    mov eax, [abs PEDMGR]
    test eax, eax
    jz .pick
    mov ebx, [rax + 4]              ; first ped in use
    mov r15d, DP_MAXPEDS
.ped:
    test ebx, ebx
    jz .pick
    dec r15d
    js .pick
    cmp ebx, r14d
    je .next
    cmp dword [rbx + PED_GAMEOBJ], 0
    je .next
    cmp dword [rbx + PED_CAR], 0
    jne .next
    cmp dword [rbx + DE_PED_GROUP], 0
    jne .next
    mov eax, [rbx + DE_PED_CLASS]
    cmp eax, 2                      ; PED_CLASS_PLAYER
    je .next
    cmp eax, 4                      ; PED_CLASS_UNSURE_SPECIAL_AI: emergency crews, cops
    je .next
    cmp eax, 5                      ; PED_CLASS_UNSURE_MISSION
    je .next
    mov ecx, [rbx + PED_POS]
    mov edx, [rbx + PED_POS + 4]
    mov r8d, [r14 + PED_POS]
    mov r9d, [r14 + PED_POS + 4]
    call de_dist
    cmp dword [rbx + DE_PED_STATE], DE_STATE_WASTED
    je .body
    cmp byte [rbx + PED_LIFE], PED_ALIVE
    jne .next
    cmp eax, [rsp]
    jge .next
    mov [rsp], eax
    mov [rsp + 4], ebx
    jmp .next
.body:
    mov ecx, [rbx + DE_PED_OBJ]
    cmp ecx, DE_OBJ_AMBULANCE
    je .next
    cmp ecx, DE_OBJ_REMOVE
    je .next
    cmp eax, [rsp + 8]
    jge .next
    mov [rsp + 8], eax
    mov r12d, ebx
.next:
    mov ebx, [rbx + PED_NEXT]
    jmp .ped
.pick:
    lea r13, [s_de_noped]
    mov ebx, r12d
    test ebx, ebx
    jz .live
    call de_road_near_ped
    lea r13, [s_de_amb_noroad]
    test eax, eax
    jz .toast
    mov dword [rsp], DE_OBJ_AMBULANCE  ; PedSetObjective(body, 28, 9999)
    mov dword [rsp + 4], 9999
    mov edi, 0x43BBC0
    mov rsi, rsp
    mov edx, 2
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
    lea r13, [s_de_amb_body]
    jmp .check
.live:
    mov ebx, [rsp + 4]
    test ebx, ebx
    jz .toast
    call de_road_near_ped
    lea r13, [s_de_amb_noroad]
    test eax, eax
    jz .toast
    mov edi, 0x4411B0               ; Ped_OnDeath(ped)
    mov rsi, rsp
    xor edx, edx
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
    lea r13, [s_de_amb_kill]
.check:
    mov edx, [rbx + DE_PED_OBJ]     ; 28 = AmbulanceManager_EnqueuePed took it
    cmp edx, DE_OBJ_AMBULANCE
    je .queued
    lea r13, [s_de_amb_full]
.queued:
    mov [de_amb_ped], ebx
    mov dword [de_amb_retry], DE_AMB_RETRIES
    lea rdi, [fmt_de_amb]
    mov esi, ebx
    mov ecx, [rbx + DE_PED_STATE]
    mov r8d, [rbx + PED_POS]
    sar r8d, 14
    mov r9d, [rbx + PED_POS + 4]
    sar r9d, 14
    xor eax, eax
    call _printf
    mov dword [de_log_left], DE_LOG_FRAMES
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
%ifdef DE_TRACE
    lea rdi, [fmt_de_toast]
    mov esi, [r_frames]
    mov rdx, r13
    mov ecx, [r14 + PED_POS]
    sar ecx, 14
    mov r8d, [r14 + PED_POS + 4]
    sar r8d, 14
    xor eax, eax
    call _printf
%endif
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = de_road_near_ped(ebx = ped): 1 if the game would find a road tile for an
; ambulance next to this ped, else 0. The same search AmbulanceManager_DispatchForQueuedPed
; makes for the body: unsure_Map_FindSpawnRoadTile 0x49D7A0, thiscall(PedPathfinder* =
; [0x66A7E4]; char kind = 1 road, u8* x, u8* y, u8* z, char wide = 0: at most 6 rings)
; -> al = 1, ret 0x14. Without one the game drops the body (objective 50) and no
; ambulance comes (measured on the Downtown start square), so nobody is killed for that.
de_road_near_ped:
    push r12
    sub rsp, 32
    mov r12, [de_low]               ; x, y, z bytes the game writes: below 4 GB
    test r12, r12
    jnz .low
    mov edi, 16
    mov esi, 16
    call low_alloc
    mov r12, rax
    mov [de_low], rax
.low:
    mov eax, [rbx + PED_POS]
    sar eax, 14
    mov [r12], al
    mov eax, [rbx + PED_POS + 4]
    sar eax, 14
    mov [r12 + 1], al
    mov eax, [rbx + PED_POS + 8]
    add eax, 0x2000
    sar eax, 14
    mov [r12 + 2], al
    xor eax, eax
    mov r8d, [abs PED_PATHFINDER]
    test r8d, r8d
    jz .out
    mov dword [rsp], 1
    mov [rsp + 4], r12d
    lea eax, [r12 + 1]
    mov [rsp + 8], eax
    lea eax, [r12 + 2]
    mov [rsp + 12], eax
    mov dword [rsp + 16], 0
    mov edi, 0x49D7A0
    mov rsi, rsp
    mov edx, 5
    xor ecx, ecx
    xor r9d, r9d
    call call32
    movzx eax, al
    cmp eax, 1
    sete al
.out:
    add rsp, 32
    pop r12
    ret

; de_call_firetruck: try the cars within DE_FIRE_RANGE nearest first (not the player's
; own), at most DE_TRIES of them, until the game grants a truck for one; with none
; granted, put a car on the nearest lane (de_spawn_on_road) and try that
de_call_firetruck:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    lea r13, [s_dm_noplayer2]
    call dm_player_ped
    test eax, eax
    jz .toast
    mov r14d, eax
    lea r13, [s_de_skipfire]
    cmp byte [abs SKIP_FIREENGINES], 0
    jne .toast
    lea r13, [s_de_fire_busy]
    mov ecx, [abs FIREENGINE_MGR]
    test ecx, ecx
    jz .toast
    mov eax, [rcx + 4]              ; both slots active: nothing to grant
    and eax, [rcx + 0x28 + 4]
    jnz .toast
    mov dword [de_ntried], 0
.try:
    cmp dword [de_ntried], DE_TRIES
    jae .spawn
    call de_nearest_car             ; ebx = untried car nearest the player (r14), or 0
    test ebx, ebx
    jz .spawn
    mov eax, [de_ntried]
    lea rcx, [de_tried]
    mov [rcx + rax*4], ebx
    inc dword [de_ntried]
    call de_request_fire
    mov r12d, eax
    lea rdi, [fmt_de_try]
    mov esi, [rbx + CAR_ID]
    mov eax, [rbx + CAR_SPRITE]
    mov edx, [rax + 0x14]
    sar edx, 14
    mov ecx, [rax + 0x18]
    sar ecx, 14
    mov r8d, [rax + 0x1c]
    sar r8d, 14
    mov r9d, r12d
    xor eax, eax
    call _printf
    mov eax, r12d
    test eax, eax
    jz .try
    jmp .granted
.spawn:
    call de_spawn_on_road           ; ebx = a car on the road tile nearest the player
    lea r13, [s_de_fire_noroad]
    test ebx, ebx
    jz .toast
    call de_request_fire
    test eax, eax
    jz .toast
.granted:
    mov r12d, eax
    lea rdi, [fmt_de_fire]
    mov esi, ebx
    mov edx, [rbx + CAR_ID]
    mov ecx, r12d
    mov eax, [rbx + CAR_SPRITE]
    mov r8d, [rax + 0x14]
    sar r8d, 14
    mov r9d, [rax + 0x18]
    sar r9d, 14
    mov r10d, [rax + 0x1c]          ; z, SCR_f
    xor eax, eax
    sub rsp, 8
    push r10
    call _printf
    add rsp, 16
    mov dword [de_log_left], DE_LOG_FRAMES
    lea r13, [s_de_fire_ok]
.toast:
    mov [dm_toast], r13
    mov dword [dm_toast_left], DM_TOAST_FRAMES
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; eax = de_lane_tile(ecx = x, edx = y, r8d = z level): the arrow bits (1 left, 2 right,
; 4 up, 8 down: TrafficSpawner_TrySpawnSide 0x4B34E0) when the tile is the middle of a
; one-way lane, else 0. Middle of a lane = the ground block (z - 1, MapBlocks_GetBlock
; 0x4653C0, thiscall(MapBlocks* = [0x662C08]; x, y, z) -> block or 0, ret 0xc; arrows
; at block +0xA & 0xF, the test unsure_Map_FindSpawnRoadTile makes) has exactly one
; arrow, and the tile is outside every RoadJunction rectangle grown by one (g_RoadNetwork
; 0x5D351C: junctionCount u16 at +4, junctions[] x 0x10 at +8, min/max X/Y at +0xc..+0xf;
; re/gta2_types.h). Why: a drive order routes to "the junction ahead of the goal tile"
; (RoadNetwork_FindRoute 0x40E030), so a goal inside a junction makes the truck drive
; through it and on round the block for ever (measured: route J(142,115) J(142,149)
; J(122,149) J(122,115) for a car at 122,149, in J(122..123,149..151)), and arrival
; (CarAI_FollowRoute 0x430320) wants the goal between two junctions of the route.
de_lane_tile:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov r12d, ecx
    mov r13d, edx
    mov [rsp], ecx
    mov [rsp + 4], edx
    dec r8d
    mov [rsp + 8], r8d
    mov edi, 0x4653C0
    mov rsi, rsp
    mov edx, 3
    xor ecx, ecx
    mov r8d, [abs MAP_BLOCKS]
    xor r9d, r9d
    call call32
    mov eax, eax                    ; call32 returns edx:eax
    test eax, eax
    jz .no
    movzx ebx, byte [rax + 0xA]
    and ebx, 0xF
    jz .no
    lea eax, [rbx - 1]              ; exactly one bit
    test eax, ebx
    jnz .no
    mov eax, [abs ROAD_NETWORK]
    test eax, eax
    jz .no
    movzx ecx, word [rax + 4]
    lea rdx, [rax + 8]
.j:
    dec ecx
    js .yes
    movzx r8d, byte [rdx + 0xc]
    dec r8d
    cmp r12d, r8d
    jl .jn
    movzx r8d, byte [rdx + 0xe]
    inc r8d
    cmp r12d, r8d
    jg .jn
    movzx r8d, byte [rdx + 0xd]
    dec r8d
    cmp r13d, r8d
    jl .jn
    movzx r8d, byte [rdx + 0xf]
    inc r8d
    cmp r13d, r8d
    jle .no                         ; inside (or next to) a junction
.jn:
    add rdx, 0x10
    jmp .j
.yes:
    mov eax, ebx
    jmp .out
.no:
    xor eax, eax
.out:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; ebx = de_spawn_on_road(): a car of the Vehicle page's model in the middle of the lane
; nearest ped r14 (de_lane_tile, ring by ring up to DE_ROAD_RINGS), or 0: SpawnCar
; 0x426AC0 (see dm_spawn_car) at the tile centre, facing along the arrow (rotation
; 0 = +y, the dm_spawn_car convention). A SpawnCar car has no driver and no category,
; so it stays where it is and is not recycled (measured: a burning one kept 3000 frames).
de_spawn_on_road:
    push r12
    push r13
    push r15
    sub rsp, 32
    xor ebx, ebx
    xor r12d, r12d                  ; ring
.ring:
    mov r15d, r12d
    neg r15d                        ; dy
.row:
    mov r13d, r12d
    neg r13d                        ; dx
.col:
    mov eax, r13d                   ; only the ring's border
    cdq
    xor eax, edx
    sub eax, edx
    mov ecx, r15d
    sar ecx, 31
    mov edx, r15d
    xor edx, ecx
    sub edx, ecx
    cmp eax, edx
    cmovl eax, edx
    cmp eax, r12d
    jne .skip
    mov ecx, [r14 + PED_POS]
    sar ecx, 14
    add ecx, r13d
    mov edx, [r14 + PED_POS + 4]
    sar edx, 14
    add edx, r15d
    mov r8d, [r14 + PED_POS + 8]
    add r8d, 0x2000
    sar r8d, 14
    call de_lane_tile
    test eax, eax
    jnz .got
.skip:
    inc r13d
    cmp r13d, r12d
    jle .col
    inc r15d
    cmp r15d, r12d
    jle .row
    inc r12d
    cmp r12d, DE_ROAD_RINGS
    jle .ring
    jmp .out
.got:
    xor ecx, ecx                    ; rotation from the arrow
    cmp eax, 2
    jne .r4
    mov ecx, 360
.r4:
    cmp eax, 4
    jne .r1
    mov ecx, 720
.r1:
    cmp eax, 1
    jne .rs
    mov ecx, 1080
.rs:
    mov [rsp + 12], ecx
    mov eax, [r14 + PED_POS]
    sar eax, 14
    add eax, r13d
    shl eax, 14
    add eax, 0x2000
    mov [rsp], eax                  ; x: tile centre
    mov eax, [r14 + PED_POS + 4]
    sar eax, 14
    add eax, r15d
    shl eax, 14
    add eax, 0x2000
    mov [rsp + 4], eax              ; y
    mov eax, [r14 + PED_POS + 8]
    add eax, 0x2000
    and eax, ~0x3FFF
    mov [rsp + 8], eax              ; z
    mov eax, [dm_model]
    lea rcx, [dm_spawnable]
    movzx eax, byte [rcx + rax]
    mov [rsp + 16], eax             ; model
    mov eax, [abs 0x5E4D4C]
    mov [rsp + 20], eax             ; scale
    mov r8d, [abs 0x5E4CA4]         ; TrafficManager*
    test r8d, r8d
    jz .out
    mov edi, 0x426AC0
    mov rsi, rsp
    mov edx, 6
    xor ecx, ecx
    xor r9d, r9d
    call call32
    mov ebx, eax
    test ebx, ebx
    jz .out
    mov [dm_last_car], ebx
    mov eax, [rbx + CAR_ID]
    mov [dm_last_car_id], eax
    lea rdi, [fmt_de_road]
    mov esi, r12d
    mov eax, [rbx + CAR_SPRITE]
    mov edx, [rax + 0x14]
    sar edx, 14
    mov ecx, [rax + 0x18]
    sar ecx, 14
    xor eax, eax
    call _printf
.out:
    add rsp, 32
    pop r15
    pop r13
    pop r12
    ret

; eax = slot + 1 after Car_RequestFireTruckAndSpawnFlames(ebx), 0 if refused
de_request_fire:
    sub rsp, 8
    mov edi, 0x41F9F0
    mov rsi, rsp
    xor edx, edx
    xor ecx, ecx
    mov r8d, ebx
    xor r9d, r9d
    call call32
    mov edi, ebx
    call de_fire_slot
    add rsp, 8
    ret

; ebx = the driverless car nearest ped r14 (Chebyshev, sprite position) within
; DE_FIRE_RANGE that is not the ped's own car and not in de_tried, or 0. Cars: g_CarPool 0x5E4CA0, in-use list
; at +4 (CarPool_GetUsedHead 0x420E50), Car.next +0x4c (re/gta2_types.h).
de_nearest_car:
    push r12
    push r13
    push r15
    xor ebx, ebx
    mov r12d, DE_FIRE_RANGE + 1
    mov eax, [abs CAR_POOL]
    test eax, eax
    jz .out
    mov r13d, [rax + 4]
    mov r15d, 1000                  ; a broken list cannot hang us
.car:
    test r13d, r13d
    jz .out
    dec r15d
    js .out
    cmp r13d, [r14 + PED_CAR]
    je .next
    cmp dword [r13 + 0x54], 0       ; driver: a driven car keeps going, the truck never
    jne .next                       ; catches it (Car_HaltAIIfHasAI does not hold traffic)
    mov eax, [r13 + CAR_SPRITE]
    test eax, eax
    jz .next
    mov ecx, [rax + 0x14]
    mov edx, [rax + 0x18]
    mov r8d, [r14 + PED_POS]
    mov r9d, [r14 + PED_POS + 4]
    call de_dist
    cmp eax, r12d
    jge .next
    push rax
    push rax
    mov eax, [r13 + CAR_SPRITE]
    mov ecx, [rax + 0x14]
    sar ecx, 14
    mov edx, [rax + 0x18]
    sar edx, 14
    mov r8d, [rax + 0x1c]
    add r8d, 0x2000
    sar r8d, 14
    call de_lane_tile               ; a car on a junction never gets its truck
    mov ecx, eax
    pop rax
    pop rdx
    test ecx, ecx
    jz .next
    mov ecx, [de_ntried]
    lea rdx, [de_tried]
.t:
    dec ecx
    js .take
    cmp [rdx + rcx*4], r13d
    je .next
    jmp .t
.take:
    mov r12d, eax
    mov ebx, r13d
.next:
    mov r13d, [r13 + 0x4c]
    jmp .car
.out:
    pop r15
    pop r13
    pop r12
    ret

; eax = 1 + index of the active FireEngineSlot whose targetCar is edi, or 0
de_fire_slot:
    xor eax, eax
    mov ecx, [abs FIREENGINE_MGR]
    test ecx, ecx
    jz .out
    cmp dword [rcx + 4], 0          ; slot 0: active, targetCar
    je .s1
    cmp [rcx + 0xc], edi
    mov eax, 1
    je .out
.s1:
    xor eax, eax
    cmp dword [rcx + 0x28 + 4], 0
    je .out
    cmp [rcx + 0x28 + 0xc], edi
    jne .out
    mov eax, 2
.out:
    ret

%ifdef DE_TRACE
; de_dump_route(edi = car): "emerg   route slot S step N: junction bounds..." for the
; car's CarAI route (CarAI +0x28 routeSlot, +0x56 routeStep; g_RoadNetwork 0x5D351C:
; junctions[545] x 0x10 at +8 with min/max X/Y at +0xc..+0xf, routes[] u16 at +0x2218,
; 0x100 per slot, 0 terminated; re/gta2_types.h RoadNetwork, RoadJunction)
de_dump_route:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test edi, edi
    jz .out
    mov eax, [rdi + 0x5c]
    test eax, eax
    jz .out
    movsx r12d, byte [rax + 0x28]   ; slot
    movzx r13d, word [rax + 0x56]   ; step
    mov r14d, edi                   ; car
    lea rdi, [fmt_de_route]
    mov esi, r12d
    mov edx, r13d
    xor eax, eax
    call _printf
    ; Seq43 bug hunt: CarAI flags (+0x24), drive order mode/followRoadActive/arrived/urgent
    ; (CarDriveOrder +8/+0x22/+0x26/+0x20) and the car's tile as the AI sees it
    mov eax, [r14 + 0x5c]
    mov r15d, [r14 + 0x60]
    test r15d, r15d
    jz .noai
    lea rdi, [fmt_de_ai]
    mov esi, [rax + 0x24]
    mov edx, [r15 + 8]
    movzx ecx, byte [r15 + 0x22]
    movzx r8d, byte [r15 + 0x26]
    movzx r9d, byte [r15 + 0x20]
    xor eax, eax
    call _printf
    mov eax, [r14 + 0x50]           ; car sprite: +0x14 x, +0x18 y, +0x1c z (Fix16)
    lea rdi, [fmt_de_ai2]
    mov esi, [r15 + 0x14]
    mov edx, [r15 + 0x18]
    mov ecx, [r15 + 0x1c]
    mov r8d, [rax + 0x14]
    mov r9d, [rax + 0x18]
    push rax
    push qword [rax + 0x1c]
    xor eax, eax
    call _printf
    add rsp, 16
.noai:
    test r12d, r12d
    jle .nl
    mov ebx, [abs 0x5D351C]
    test ebx, ebx
    jz .nl
    xor r14d, r14d
.j:
    mov eax, r12d
    shl eax, 8
    add eax, r14d
    movzx r15d, word [rbx + 0x2218 + rax*2]
    test r15d, r15d
    jz .nl
    shl r15d, 4
    lea rdi, [fmt_de_junc]
    movzx esi, byte [rbx + r15 + 8 + 0xc]
    movzx edx, byte [rbx + r15 + 8 + 0xd]
    movzx ecx, byte [rbx + r15 + 8 + 0xe]
    movzx r8d, byte [rbx + r15 + 8 + 0xf]
    xor eax, eax
    call _printf
    inc r14d
    cmp r14d, 12
    jb .j
.nl:
    lea rdi, [fmt_de_nl]
    xor eax, eax
    call _printf
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

%endif

; eax = block x, edx = block y of car edi, or -1, -1
de_carpos:
    mov eax, -1
    mov edx, -1
    test edi, edi
    jz .out
    mov ecx, [rdi + CAR_SPRITE]
    test ecx, ecx
    jz .out
    mov eax, [rcx + 0x14]
    sar eax, 14
    mov edx, [rcx + 0x18]
    sar edx, 14
.out:
    ret

%ifdef DE_TRACE
; de_log: while de_log_left runs, every DE_LOG_EVERY frames print the player position,
; the two AmbulanceSlots (state, EmergencyVehicleSlot stage, ambulance position) and the
; two FireEngineSlots (active, state, truck position)
de_log:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov eax, [de_log_left]
    test eax, eax
    jz .out
    dec eax
    mov [de_log_left], eax
    cmp eax, DE_LOG_FRAMES - 40     ; every frame right after a call
    jae .now
    xor edx, edx
    mov ecx, DE_LOG_EVERY
    div ecx
    test edx, edx
    jnz .out
.now:
    call dm_player_ped
    test eax, eax
    jz .out
    mov r8d, [de_amb_ped]           ; the body we queued: objective, state
    test r8d, r8d
    jz .np
    push rax
    push rax
    lea rdi, [fmt_de_log_body]
    mov esi, [r8 + DE_PED_OBJ]
    mov edx, [r8 + DE_PED_STATE]
    mov ecx, [r8 + PED_POS + 8]
    xor r8d, r8d                    ; EmergencyVehiclePool slots in use
    mov eax, [abs 0x672B90]
    test eax, eax
    jz .pc
    xor r9d, r9d
.pl:
    imul r10d, r9d, 0x30
    movzx r10d, byte [rax + r10 + 0x1e]
    add r8d, r10d
    inc r9d
    cmp r9d, 10
    jb .pl
.pc:
    mov r9d, -1                     ; PedPathfinder +0x38 busy
    mov eax, [abs PED_PATHFINDER]
    test eax, eax
    jz .pf
    movzx r9d, byte [rax + 0x38]
.pf:
    xor eax, eax
    call _printf
    pop rax
    pop rax
.np:
    lea rdi, [fmt_de_log_player]
    mov esi, [r_frames]
    mov edx, [rax + PED_POS]
    sar edx, 14
    mov ecx, [rax + PED_POS + 4]
    sar ecx, 14
    movsx r8d, word [rax + 0x216]   ; health
    xor eax, eax
    call _printf
    mov ebx, [abs AMBULANCE_MGR]
    test ebx, ebx
    jz .fire
    xor r12d, r12d
.amb:
    lea r13, [rbx + 0xD0]
    mov eax, r12d
    shl eax, 5
    add r13, rax                    ; AmbulanceSlot
    mov r14d, -1                    ; stage
    xor r15d, r15d                  ; car
    mov eax, [r13 + 4]              ; EmergencyVehicleSlot*
    test eax, eax
    jz .ap
    mov r14d, [rax + 0x28]
    mov r15d, [rax]
.ap:
    mov edi, r15d
    call de_carpos
    lea rdi, [fmt_de_log_amb]
    mov esi, r12d
    mov r8d, eax
    mov r9d, edx
    mov edx, [r13 + 0x18]
    mov ecx, r14d
    movzx r10d, byte [rbx + 1]      ; pendingCount
    xor eax, eax
    sub rsp, 8
    push r10
    call _printf
    add rsp, 16
    mov edi, r15d                   ; the ambulance's route and drive order
    call de_dump_route
    inc r12d
    cmp r12d, 2
    jb .amb
.fire:
    mov ebx, [abs FIREENGINE_MGR]
    test ebx, ebx
    jz .out
    xor r12d, r12d
.fs:
    imul r13d, r12d, 0x28
    add r13d, ebx                   ; FireEngineSlot
    mov edi, [r13 + 0x1c]           ; truck
    call de_carpos
    lea rdi, [fmt_de_log_fire]
    mov esi, r12d
    mov r8d, eax
    mov r9d, edx
    mov edx, [r13 + 4]
    mov ecx, [r13 + 8]
    movzx eax, word [r13 + 0x24]
    shl eax, 16
    or ecx, eax                     ; state | timer << 16
    mov r10d, -1                    ; truck: routeSlot << 24 | drive order target x << 8 | y
    mov r11d, [r13 + 0x1c]
    test r11d, r11d
    jz .fd
    mov eax, [r11 + 0x5c]           ; CarAI*
    test eax, eax
    jz .fd
    movsx r10d, byte [rax + 0x28]
    shl r10d, 24
    mov eax, [r11 + 0x60]           ; CarDriveOrder*
    test eax, eax
    jz .fd
    mov ecx, [rax + 0x14]
    sar ecx, 14
    and ecx, 0xff
    shl ecx, 8
    or r10d, ecx
    mov ecx, [rax + 0x18]
    sar ecx, 14
    and ecx, 0xff
    or r10d, ecx
.fd:
    xor eax, eax
    sub rsp, 8
    push r10
    call _printf
    add rsp, 16
    mov edi, [r13 + 0x1c]
    call de_dump_route
    inc r12d
    cmp r12d, 2
    jb .fs
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
%endif

section .data
align 8
de_low:      dq 0
    DMVALUE ambulance
    DMVALUE firetruck
    DM_ITEM  dmp_player, 70, DM_VALUE, "Call ambulance", dmv_ambulance
    DM_ITEM  dmp_player, 80, DM_VALUE, "Call fire truck", dmv_firetruck
    DM_FRAME 30, de_run
de_log_left: dd 0
de_req:      db 0
de_assist:   db 0
align 4
de_amb_ped:  dd 0
de_amb_retry: dd 0
de_args:     dd 0, 0
align 4
de_prev:     dd 0, 0, -1, -1      ; fire slot states, ambulance stages
align 4
de_ntried:   dd 0
de_tried:    times DE_TRIES dd 0
align 8

section .rodata
s_de_noped:      db "No ped nearby", 0
s_de_skipamb:    db "Ambulances are off", 0
s_de_skipfire:   db "Fire engines are off", 0
s_de_amb_body:   db "Ambulance called", 0
s_de_amb_kill:   db "Ambulance called (ped killed)", 0
s_de_amb_noroad: db "No road near the ped for an ambulance", 0
s_de_amb_full:   db "No ambulance: queue full", 0
s_de_fire_ok:    db "Fire truck called", 0
s_de_fire_busy:  db "Fire truck already coming", 0
s_de_fire_noroad: db "No fire truck: no road or slot", 0
fmt_de_amb:      db "emerg: ambulance for ped %08x objective %d state %d at %d,%d", 10, 0
fmt_de_try:      db "emerg: try car id %d at %d,%d,%d -> %d", 10, 0
fmt_de_road: db "emerg: car put mid-lane, ring %d, at %d,%d", 10, 0
fmt_de_chg_fire: db "emerg: f%d fire slot%d state %d (was %d), truck x %d, spawned car life %d", 10, 0
fmt_de_chg_amb: db "emerg: f%d ambulance slot%d stage %d (was %d)", 10, 0
fmt_de_log_body: db "emerg   body objective %d state %d z %x, emergency pool in use %d, pathfinder busy %d", 10, 0
fmt_de_requeue: db "emerg: f%d body dropped by the game, queued again", 10, 0
fmt_de_route: db "emerg   route slot %d step %d:", 0
fmt_de_ai: db "emerg   ai flags %08x order mode %d followRoad %d arrived %d urgent %d", 10, 0
fmt_de_ai2: db "emerg   order target %x,%x,%x car pos %x,%x,%x", 10, 0
fmt_de_toast: db "emerg: f%d call ambulance: %s (player %d,%d)", 10, 0
fmt_de_consts: db "emerg: consts 5e512c=%x 5e50b8=%x 5e520c=%x 5e5398=%x", 10, 0
fmt_de_junc: db " (%d,%d-%d,%d)", 0
fmt_de_nl: db 10, 0
fmt_de_fire:     db "emerg: fire truck for car %08x id %d slot %d at %d,%d z %x", 10, 0
fmt_de_log_player: db "emerg f%d: player %d,%d health %d", 10, 0
fmt_de_log_amb:  db "emerg   amb slot%d state %d stage %d car %d,%d queue %d", 10, 0
fmt_de_log_fire: db "emerg   fire slot%d active %d state %d truck %d,%d route|target %08x", 10, 0
