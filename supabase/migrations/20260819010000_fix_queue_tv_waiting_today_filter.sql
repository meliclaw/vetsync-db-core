-- Fix: get_queue_tv_display() dropped patients from the "waiting" list who
-- were still legitimately waiting (never finalized) but whose scheduled_at
-- fell on a prior calendar day. The internal Fila/Esteira board
-- (useQueueFromEsteira) has no such date restriction — it lists every
-- active, non-FINALIZADO appointment regardless of scheduled date — so the
-- two views disagreed: staff's Fila page correctly showed "5 pacientes"
-- waiting while the waiting-room TV display showed "Nenhum aguardando" for
-- the same unit at the same moment. Reproduced live in production
-- (unit BestZoo Aphaville, 2026-08-18): Fila = 5, TV = 0.
--
-- Fix: drop the v_today_start/v_today_end bound on the waiting CTE so it
-- matches the Esteira board's semantics — any active appointment still in
-- SCHEDULED/CONFIRMED, or IN_PROGRESS-but-not-yet-started, regardless of
-- which day it was originally scheduled for.
CREATE OR REPLACE FUNCTION public.get_queue_tv_display(p_unit_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today_start timestamptz := date_trunc('day', now() AT TIME ZONE 'America/Sao_Paulo') AT TIME ZONE 'America/Sao_Paulo';
  v_today_end   timestamptz := v_today_start + interval '1 day';
  v_waiting jsonb;
  v_called  jsonb;
  v_recent  jsonb;
  v_current_appointment_id uuid;
BEGIN
  IF p_unit_id IS NULL THEN
    RETURN jsonb_build_object('waiting', '[]'::jsonb, 'called', NULL, 'recent', '[]'::jsonb, 'server_time', now());
  END IF;

  SELECT COALESCE(jsonb_agg(row_to_json(w) ORDER BY w.recebido_em), '[]'::jsonb)
  INTO v_waiting
  FROM (
    SELECT
      a.id,
      a.appointment_number,
      p.name AS patient_name,
      g.full_name AS guardian_name,
      ws.id AS stage_id,
      ws.name AS stage_name,
      ws.color_hex AS stage_color,
      sr.name AS room_name,
      a.priority AS urgency,
      a.scheduled_at AS recebido_em
    FROM public.appointments a
    LEFT JOIN public.patients p ON p.id = a.patient_id
    LEFT JOIN public.guardians g ON g.id = a.guardian_id
    LEFT JOIN public.workflow_stages ws ON ws.id = a.current_workflow_stage_id
    LEFT JOIN public.service_rooms sr ON sr.id = a.service_room_id
    WHERE a.unit_id = p_unit_id
      AND a.is_active = true
      AND a.deleted_at IS NULL
      AND (
        a.status IN ('SCHEDULED','CONFIRMED')
        OR (a.status = 'IN_PROGRESS' AND a.started_at IS NULL)
      )
    ORDER BY a.scheduled_at
    LIMIT 20
  ) w;

  SELECT c.appointment_id, to_jsonb(c) - 'appointment_id'
  INTO v_current_appointment_id, v_called
  FROM (
    SELECT
      a.id AS appointment_id,
      COALESCE(a.last_called_at, a.updated_at) AS last_called_at,
      jsonb_strip_nulls(
        COALESCE(a.last_called_payload, '{}'::jsonb)
        || jsonb_build_object(
          'appointment_id', a.id,
          'appointment_number', a.appointment_number,
          'patient_name', COALESCE((a.last_called_payload->>'patient_name'), p.name),
          'guardian_name', COALESCE((a.last_called_payload->>'guardian_name'), g.full_name),
          'stage_name', COALESCE((a.last_called_payload->>'stage_name'), ws.name),
          'stage_color', COALESCE((a.last_called_payload->>'stage_color'), ws.color_hex),
          'room_name', COALESCE((a.last_called_payload->>'room_name'), sr.name),
          'room_code', COALESCE((a.last_called_payload->>'room_code'), sr.code),
          'professional_name', COALESCE((a.last_called_payload->>'professional_name'), pr.full_name),
          'specialization_name', COALESCE((a.last_called_payload->>'specialization_name'), sp.name),
          'urgency', COALESCE((a.last_called_payload->>'urgency'), a.priority),
          'called_from', COALESCE((a.last_called_payload->>'called_from'), 'queue')
        )
      ) AS last_called_payload
    FROM public.appointments a
    LEFT JOIN public.patients p ON p.id = a.patient_id
    LEFT JOIN public.guardians g ON g.id = a.guardian_id
    LEFT JOIN public.workflow_stages ws ON ws.id = a.current_workflow_stage_id
    LEFT JOIN public.service_rooms sr ON sr.id = a.service_room_id
    LEFT JOIN public.profiles pr ON pr.id = a.veterinarian_id
    LEFT JOIN public.specializations sp ON sp.id = a.specialization_id
    WHERE a.unit_id = p_unit_id
      AND a.is_active = true
      AND a.deleted_at IS NULL
      AND a.status = 'IN_PROGRESS'
      AND a.last_called_at IS NOT NULL
      AND a.last_called_at >= v_today_start
      AND a.last_called_at < v_today_end
    ORDER BY a.last_called_at DESC
    LIMIT 1
  ) c;

  SELECT COALESCE(jsonb_agg(row_to_json(r) ORDER BY r.last_called_at DESC), '[]'::jsonb)
  INTO v_recent
  FROM (
    SELECT
      a.id,
      a.last_called_at,
      jsonb_strip_nulls(
        COALESCE(a.last_called_payload, '{}'::jsonb)
        || jsonb_build_object(
          'appointment_id', a.id,
          'appointment_number', a.appointment_number,
          'patient_name', COALESCE((a.last_called_payload->>'patient_name'), p.name),
          'guardian_name', COALESCE((a.last_called_payload->>'guardian_name'), g.full_name),
          'stage_name', COALESCE((a.last_called_payload->>'stage_name'), ws.name),
          'stage_color', COALESCE((a.last_called_payload->>'stage_color'), ws.color_hex),
          'room_name', COALESCE((a.last_called_payload->>'room_name'), sr.name),
          'room_code', COALESCE((a.last_called_payload->>'room_code'), sr.code),
          'professional_name', COALESCE((a.last_called_payload->>'professional_name'), pr.full_name),
          'specialization_name', COALESCE((a.last_called_payload->>'specialization_name'), sp.name),
          'urgency', COALESCE((a.last_called_payload->>'urgency'), a.priority),
          'called_from', COALESCE((a.last_called_payload->>'called_from'), 'queue')
        )
      ) AS last_called_payload
    FROM public.appointments a
    LEFT JOIN public.patients p ON p.id = a.patient_id
    LEFT JOIN public.guardians g ON g.id = a.guardian_id
    LEFT JOIN public.workflow_stages ws ON ws.id = a.current_workflow_stage_id
    LEFT JOIN public.service_rooms sr ON sr.id = a.service_room_id
    LEFT JOIN public.profiles pr ON pr.id = a.veterinarian_id
    LEFT JOIN public.specializations sp ON sp.id = a.specialization_id
    WHERE a.unit_id = p_unit_id
      AND a.is_active = true
      AND a.deleted_at IS NULL
      AND a.last_called_at IS NOT NULL
      AND a.last_called_at >= v_today_start
      AND a.last_called_at < v_today_end
      AND (v_current_appointment_id IS NULL OR a.id <> v_current_appointment_id)
    ORDER BY a.last_called_at DESC
    LIMIT 4
  ) r;

  RETURN jsonb_build_object(
    'waiting', v_waiting,
    'called', v_called,
    'recent', v_recent,
    'server_time', now()
  );
END;
$function$;
