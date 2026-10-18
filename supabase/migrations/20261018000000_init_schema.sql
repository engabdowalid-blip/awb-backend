-- 1. جدول الشركات (النظام المتعدد)
CREATE TABLE companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW() AT TIME ZONE 'Africa/Cairo'
);

-- 2. جدول الفروع
CREATE TABLE branches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    radius_m INTEGER DEFAULT 100,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW() AT TIME ZONE 'Africa/Cairo'
);

-- 3. جدول الموظفين والصلاحيات (Profiles)
CREATE TYPE user_role AS ENUM ('owner', 'branch_manager', 'employee');

CREATE TABLE profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    branch_id UUID REFERENCES branches(id) ON DELETE SET NULL,
    role user_role NOT NULL DEFAULT 'employee',
    employee_code VARCHAR(50) NOT NULL,
    full_name VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    deleted_at TIMESTAMPTZ, -- للاحتفاظ بالموظف عند استقالته (Soft Delete)
    created_at TIMESTAMPTZ DEFAULT NOW() AT TIME ZONE 'Africa/Cairo',
    UNIQUE (company_id, employee_code)
);

-- 4. جدول الشيفتات
CREATE TABLE shifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    branch_id UUID REFERENCES branches(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    start_time TIME NOT NULL,
    end_time TIME NOT NULL,
    grace_minutes INTEGER DEFAULT 30,
    early_checkin_minutes INTEGER DEFAULT 30,
    is_active BOOLEAN DEFAULT true
);

-- 5. إسناد الشيفتات للموظفين
CREATE TABLE shift_assignments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    shift_id UUID NOT NULL REFERENCES shifts(id) ON DELETE CASCADE,
    shift_date DATE NOT NULL,
    created_by UUID REFERENCES profiles(id),
    UNIQUE (employee_id, shift_date) -- منع إسناد أكثر من شيفت في نفس اليوم للموظف
);

-- 6. سجلات الحضور والانصراف
CREATE TYPE attendance_kind AS ENUM ('check_in', 'check_out');

CREATE TABLE attendance_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    branch_id UUID NOT NULL REFERENCES branches(id),
    shift_assignment_id UUID REFERENCES shift_assignments(id),
    kind attendance_kind NOT NULL,
    server_recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW() AT TIME ZONE 'Africa/Cairo',
    device_reported_at TIMESTAMPTZ NOT NULL,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    accuracy_m DOUBLE PRECISION,
    is_proxy BOOLEAN DEFAULT false,
    proxy_reason TEXT,
    proxy_approved_by UUID REFERENCES profiles(id),
    UNIQUE (employee_id, shift_assignment_id, kind) -- منع التسجيل المكرر
);

-- 7. قواعد خصومات التأخير (يتم حمايتها بحيث لا يراها سوى الـ Owner)
CREATE TABLE late_penalty_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    branch_id UUID REFERENCES branches(id),
    min_late_minutes INTEGER NOT NULL,
    max_late_minutes INTEGER,
    amount DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(10) DEFAULT 'EGP',
    is_active BOOLEAN DEFAULT true
);

-- 8. حالات الخصم (البيانات العامة للمدير والموظف)
CREATE TYPE penalty_status AS ENUM ('pending_approval', 'approved', 'rejected', 'cancelled');

CREATE TABLE penalty_cases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    attendance_event_id UUID NOT NULL REFERENCES attendance_events(id),
    late_minutes INTEGER NOT NULL,
    status penalty_status DEFAULT 'pending_approval',
    created_at TIMESTAMPTZ DEFAULT NOW() AT TIME ZONE 'Africa/Cairo',
    reviewed_by UUID REFERENCES profiles(id),
    reviewed_at TIMESTAMPTZ,
    review_note TEXT
);

-- 9. التفاصيل المالية للخصومات (السرية المطلقة)
CREATE TABLE penalty_financials (
    penalty_case_id UUID PRIMARY KEY REFERENCES penalty_cases(id) ON DELETE CASCADE,
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    amount DECIMAL(10, 2) NOT NULL,
    currency VARCHAR(10) DEFAULT 'EGP'
);

-- 10. سجل التدقيق (Audit Logs)
CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
    actor_id UUID REFERENCES profiles(id),
    action VARCHAR(100) NOT NULL,
    entity_type VARCHAR(50) NOT NULL,
    entity_id UUID NOT NULL,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW() AT TIME ZONE 'Africa/Cairo'
);

-- تفعيل RLS على جميع الجداول
ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE late_penalty_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE penalty_cases ENABLE ROW LEVEL SECURITY;
ALTER TABLE penalty_financials ENABLE ROW LEVEL SECURITY;

-- دالة مساعدة سريعة لجلب بيانات المستخدم الحالي
CREATE OR REPLACE FUNCTION auth_user_company_id() RETURNS UUID AS $$
  SELECT company_id FROM public.profiles WHERE id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth_user_role() RETURNS text AS $$
  SELECT role::text FROM public.profiles WHERE id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth_user_branch_id() RETURNS UUID AS $$
  SELECT branch_id FROM public.profiles WHERE id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- 1. سياسة الفروع والموظفين (الكل يرى بيانات شركته فقط)
CREATE POLICY "Users can view branches of their company" ON branches
  FOR SELECT USING (company_id = auth_user_company_id());

CREATE POLICY "Users can view active profiles of their company" ON profiles
  FOR SELECT USING (company_id = auth_user_company_id() AND deleted_at IS NULL);

-- 2. سياسات الخصومات (الشفافية للإداريات، السرية للماليات)
-- الموظف يرى حالة الخصم الخاصة به، ومسؤول الفرع يرى خصومات فرعه
CREATE POLICY "View penalty cases" ON penalty_cases
  FOR SELECT USING (
    company_id = auth_user_company_id() AND (
      auth_user_role() = 'owner' OR
      (auth_user_role() = 'branch_manager' AND employee_id IN (SELECT id FROM profiles WHERE branch_id = auth_user_branch_id())) OR
      (auth_user_role() = 'employee' AND employee_id = auth.uid())
    )
  );

-- السرية المالية: الـ Owner فقط هو من يرى المبالغ المالية وقواعد الخصم!
CREATE POLICY "Owners ONLY view penalty rules" ON late_penalty_rules
  FOR ALL USING (company_id = auth_user_company_id() AND auth_user_role() = 'owner');

CREATE POLICY "Owners ONLY view financials" ON penalty_financials
  FOR ALL USING (company_id = auth_user_company_id() AND auth_user_role() = 'owner');
