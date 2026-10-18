-- 1. دالة حساب المسافة الجغرافية (بالمتر) بين نقطتين
CREATE OR REPLACE FUNCTION calculate_distance(
  lat1 DOUBLE PRECISION, lon1 DOUBLE PRECISION,
  lat2 DOUBLE PRECISION, lon2 DOUBLE PRECISION
) RETURNS DOUBLE PRECISION AS $$
DECLARE
  r DOUBLE PRECISION := 6371000; -- نصف قطر الأرض بالمتر
  phi1 DOUBLE PRECISION := radians(lat1);
  phi2 DOUBLE PRECISION := radians(lat2);
  dphi DOUBLE PRECISION := radians(lat2 - lat1);
  dlambda DOUBLE PRECISION := radians(lon2 - lon1);
  a DOUBLE PRECISION;
  c DOUBLE PRECISION;
BEGIN
  a := sin(dphi / 2) * sin(dphi / 2) +
       cos(phi1) * cos(phi2) *
       sin(dlambda / 2) * sin(dlambda / 2);
  c := 2 * atan2(sqrt(a), sqrt(1 - a));
  RETURN r * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- 2. دالة تسجيل الحضور والانصراف الآمنة
CREATE OR REPLACE FUNCTION record_attendance(
  p_employee_id UUID,
  p_branch_id UUID,
  p_latitude DOUBLE PRECISION,
  p_longitude DOUBLE PRECISION,
  p_accuracy DOUBLE PRECISION,
  p_kind text -- 'check_in' or 'check_out'
) RETURNS JSONB AS $$
DECLARE
  v_company_id UUID;
  v_branch_lat DOUBLE PRECISION;
  v_branch_lon DOUBLE PRECISION;
  v_radius INTEGER;
  v_distance DOUBLE PRECISION;
  v_shift_assignment_id UUID;
  v_event_id UUID;
BEGIN
  -- 1. التأكد من وجود الموظف وحسابه نشط
  SELECT company_id INTO v_company_id FROM profiles 
  WHERE id = p_employee_id AND is_active = true AND deleted_at IS NULL;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'الموظف غير موجود أو الحساب معطل');
  END IF;

  -- 2. جلب بيانات الفرع
  SELECT latitude, longitude, radius_m INTO v_branch_lat, v_branch_lon, v_radius
  FROM branches 
  WHERE id = p_branch_id AND company_id = v_company_id AND is_active = true;
  
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'الفرع غير صحيح أو غير مفعل');
  END IF;

  -- 3. حساب مسافة الـ GPS والتأكد من النطاق
  v_distance := calculate_distance(p_latitude, p_longitude, v_branch_lat, v_branch_lon);
  IF v_distance > v_radius THEN
    RETURN jsonb_build_object('success', false, 'message', 'أنت خارج النطاق المسموح للفرع', 'distance_m', v_distance);
  END IF;

  -- 4. التأكد من وجود شيفت للموظف اليوم
  SELECT id INTO v_shift_assignment_id FROM shift_assignments
  WHERE employee_id = p_employee_id AND shift_date = CURRENT_DATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'message', 'لا يوجد شيفت مسند لك اليوم');
  END IF;

  -- 5. تسجيل الحدث (مع منع التكرار)
  BEGIN
    INSERT INTO attendance_events (
      company_id, employee_id, branch_id, shift_assignment_id, kind, device_reported_at, latitude, longitude, accuracy_m
    ) VALUES (
      v_company_id, p_employee_id, p_branch_id, v_shift_assignment_id, p_kind::attendance_kind, now(), p_latitude, p_longitude, p_accuracy
    ) RETURNING id INTO v_event_id;
  EXCEPTION WHEN unique_violation THEN
     RETURN jsonb_build_object('success', false, 'message', 'تم تسجيل هذا الحدث مسبقاً اليوم');
  END;

  RETURN jsonb_build_object('success', true, 'message', 'تم التسجيل بنجاح', 'event_id', v_event_id, 'distance_m', v_distance);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
