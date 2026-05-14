-- ══════════════════════════════════════════════════════════════
-- NUTRICONSULT PRO — Setup completo do banco de dados Supabase
-- Execute este script no Supabase SQL Editor
-- ══════════════════════════════════════════════════════════════

-- ── 1. PERFIS DE USUÁRIO ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id          UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nome        TEXT NOT NULL,
  crn         TEXT,
  cargo       TEXT NOT NULL DEFAULT 'consultor',
  -- cargo: consultor | nutricionista | tecnico | estagiario | admin_estab
  telefone    TEXT,
  consultoria TEXT,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ DEFAULT now(),
  updated_at  TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Usuário vê próprio perfil" ON public.profiles
  FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Usuário edita próprio perfil" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Inserir perfil no cadastro" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);

-- Trigger: cria perfil automaticamente ao cadastrar usuário
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, nome, cargo)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'nome', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'cargo', 'consultor')
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ── 2. UANs ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.uans (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  consultor_id  UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  nome          TEXT NOT NULL,
  razao_social  TEXT,
  cnpj          TEXT,
  endereco      TEXT,
  cidade        TEXT,
  estado        TEXT DEFAULT 'SP',
  telefone      TEXT,
  tipo          TEXT DEFAULT 'corporativo',
  -- tipo: corporativo | hospitalar | escolar | campo | popular | catering
  capacidade    INTEGER,
  ativo         BOOLEAN DEFAULT true,
  meta_conformidade   NUMERIC(5,2) DEFAULT 85.0,
  meta_custo_per_cap  NUMERIC(8,2) DEFAULT 9.0,
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.uans ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Consultor vê suas UANs" ON public.uans
  FOR ALL USING (consultor_id = auth.uid());

-- ── 3. MEMBROS DA EQUIPE ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.equipe (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id        UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  consultor_id  UUID NOT NULL REFERENCES public.profiles(id),
  nome          TEXT NOT NULL,
  cargo         TEXT NOT NULL,
  -- cargo: nutricionista | tecnico | estagiario | assistente | cozinheiro
  crn           TEXT,
  email         TEXT,
  telefone      TEXT,
  login_usuario TEXT UNIQUE,
  status        TEXT DEFAULT 'ativo',
  -- status: ativo | folga | ferias | afastado
  permissoes    JSONB DEFAULT '{
    "dashboard": true,
    "checklists": true,
    "nao_conformidades": true,
    "fichas_tecnicas": false,
    "pops_mbp": false,
    "equipe": false,
    "relatorios": false,
    "financeiro": false
  }'::jsonb,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.equipe ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Consultor gerencia equipe" ON public.equipe
  FOR ALL USING (consultor_id = auth.uid());

-- ── 4. CHECKLISTS ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.checklists (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id        UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  data          DATE NOT NULL DEFAULT CURRENT_DATE,
  turno         TEXT DEFAULT 'manha',
  -- turno: manha | tarde | noite
  responsavel   TEXT,
  conformidade  NUMERIC(5,2),
  total_itens   INTEGER DEFAULT 0,
  itens_ok      INTEGER DEFAULT 0,
  itens_nc      INTEGER DEFAULT 0,
  itens_na      INTEGER DEFAULT 0,
  itens_pend    INTEGER DEFAULT 0,
  finalizado    BOOLEAN DEFAULT false,
  assinado_por  TEXT,
  assinado_em   TIMESTAMPTZ,
  observacoes   TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.checklists ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso checklist por UAN" ON public.checklists
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 5. ITENS DO CHECKLIST ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.checklist_itens (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_id    UUID NOT NULL REFERENCES public.checklists(id) ON DELETE CASCADE,
  categoria       TEXT NOT NULL,
  -- categoria: recebimento | manipuladores | higiene | temperatura | pragas | documentacao
  descricao       TEXT NOT NULL,
  status          TEXT DEFAULT 'pendente',
  -- status: pendente | conforme | nao_conforme | na
  temperatura     NUMERIC(5,2),
  responsavel     TEXT,
  horario         TIMETZ,
  observacao      TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.checklist_itens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso itens via checklist" ON public.checklist_itens
  FOR ALL USING (
    checklist_id IN (
      SELECT c.id FROM public.checklists c
      JOIN public.uans u ON u.id = c.uan_id
      WHERE u.consultor_id = auth.uid()
    )
  );

-- ── 6. NÃO CONFORMIDADES ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.nao_conformidades (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id          UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  checklist_id    UUID REFERENCES public.checklists(id),
  data            DATE NOT NULL DEFAULT CURRENT_DATE,
  horario         TIMETZ,
  categoria       TEXT NOT NULL,
  severidade      TEXT NOT NULL DEFAULT 'moderada',
  -- severidade: critica | moderada | leve
  descricao       TEXT NOT NULL,
  local           TEXT,
  acao_imediata   TEXT,
  acao_corretiva  TEXT,
  responsavel     TEXT,
  prazo           DATE,
  status          TEXT DEFAULT 'aberta',
  -- status: aberta | em_acao | resolvida
  resolvido_em    TIMESTAMPTZ,
  foto_url        TEXT,
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.nao_conformidades ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso NCs por UAN" ON public.nao_conformidades
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 7. FICHAS TÉCNICAS ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.fichas_tecnicas (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id          UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  codigo          TEXT,
  nome            TEXT NOT NULL,
  categoria       TEXT,
  -- categoria: proteina | guarnicao | salada | sobremesa | sopa | acompanhamento
  n_porcoes       INTEGER NOT NULL DEFAULT 100,
  responsavel     TEXT,
  versao          TEXT DEFAULT 'v1.0',
  temp_servico    TEXT,
  temp_coccao     TEXT,
  tempo_preparo   TEXT,
  rendimento_fcc  NUMERIC(5,3) DEFAULT 0.85,
  -- Totais calculados (por porção)
  kcal_porcao     NUMERIC(8,2),
  ptn_porcao      NUMERIC(8,2),
  cho_porcao      NUMERIC(8,2),
  lip_porcao      NUMERIC(8,2),
  fib_porcao      NUMERIC(8,2),
  custo_porcao    NUMERIC(10,2),
  custo_total     NUMERIC(10,2),
  modo_preparo    TEXT,
  observacoes     TEXT,
  ativo           BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.fichas_tecnicas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso FTPs por UAN" ON public.fichas_tecnicas
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 8. INGREDIENTES DA FICHA TÉCNICA ─────────────────────────
CREATE TABLE IF NOT EXISTS public.ftp_ingredientes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ftp_id        UUID NOT NULL REFERENCES public.fichas_tecnicas(id) ON DELETE CASCADE,
  taco_id       INTEGER,
  nome          TEXT NOT NULL,
  fonte         TEXT DEFAULT 'TACO',
  peso_bruto_g  NUMERIC(10,2) NOT NULL,
  fc            NUMERIC(5,3) DEFAULT 1.0,
  peso_liq_g    NUMERIC(10,2),
  custo_kg      NUMERIC(10,2) DEFAULT 0,
  -- Valores nutricionais por 100g (da TACO)
  kcal_100g     NUMERIC(8,2) DEFAULT 0,
  ptn_100g      NUMERIC(8,2) DEFAULT 0,
  cho_100g      NUMERIC(8,2) DEFAULT 0,
  lip_100g      NUMERIC(8,2) DEFAULT 0,
  fib_100g      NUMERIC(8,2) DEFAULT 0,
  sodio_100g    NUMERIC(8,2) DEFAULT 0,
  calcio_100g   NUMERIC(8,2) DEFAULT 0,
  ferro_100g    NUMERIC(8,2) DEFAULT 0,
  vitc_100g     NUMERIC(8,2) DEFAULT 0,
  ordem         INTEGER DEFAULT 0,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.ftp_ingredientes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso ingredientes via FTP" ON public.ftp_ingredientes
  FOR ALL USING (
    ftp_id IN (
      SELECT ft.id FROM public.fichas_tecnicas ft
      JOIN public.uans u ON u.id = ft.uan_id
      WHERE u.consultor_id = auth.uid()
    )
  );

-- ── 9. POPs ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pops (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id          UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  numero          TEXT NOT NULL,
  titulo          TEXT NOT NULL,
  base_legal      TEXT DEFAULT 'RDC 216/2004 — ANVISA',
  objetivo        TEXT,
  versao          TEXT DEFAULT 'v1.0',
  responsavel     TEXT,
  frequencia      TEXT DEFAULT 'Diária',
  revisao_period  TEXT DEFAULT 'Semestral',
  data_elaboracao DATE DEFAULT CURRENT_DATE,
  data_revisao    DATE,
  proxima_revisao DATE,
  conteudo        TEXT,
  -- JSON com seções do POP
  status          TEXT DEFAULT 'vigente',
  -- status: vigente | vencendo | vencido | rascunho
  obrigatorio     BOOLEAN DEFAULT true,
  created_at      TIMESTAMPTZ DEFAULT now(),
  updated_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.pops ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso POPs por UAN" ON public.pops
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 10. TAREFAS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.tarefas (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id        UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  titulo        TEXT NOT NULL,
  descricao     TEXT,
  categoria     TEXT,
  prioridade    TEXT DEFAULT 'media',
  -- prioridade: alta | media | baixa
  status        TEXT DEFAULT 'pendente',
  -- status: pendente | em_andamento | concluida
  responsavel   TEXT,
  prazo         DATE,
  recorrencia   TEXT DEFAULT 'unica',
  concluida_em  TIMESTAMPTZ,
  created_by    UUID REFERENCES public.profiles(id),
  created_at    TIMESTAMPTZ DEFAULT now(),
  updated_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.tarefas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso tarefas por UAN" ON public.tarefas
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 11. TEMPERATURAS ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.temperaturas (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id        UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  checklist_id  UUID REFERENCES public.checklists(id),
  data          DATE NOT NULL DEFAULT CURRENT_DATE,
  horario       TIMETZ NOT NULL,
  equipamento   TEXT NOT NULL,
  temperatura   NUMERIC(5,2) NOT NULL,
  limite_min    NUMERIC(5,2),
  limite_max    NUMERIC(5,2),
  status        TEXT,
  -- Calculado: ok | alerta | critico
  responsavel   TEXT,
  observacao    TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.temperaturas ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso temps por UAN" ON public.temperaturas
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 12. RELATÓRIOS ────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.relatorios (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  uan_id          UUID NOT NULL REFERENCES public.uans(id) ON DELETE CASCADE,
  periodo_inicio  DATE NOT NULL,
  periodo_fim     DATE NOT NULL,
  semanas         TEXT,
  conformidade    NUMERIC(5,2),
  total_registros INTEGER DEFAULT 0,
  total_ncs       INTEGER DEFAULT 0,
  custo_medio     NUMERIC(10,2),
  dados_json      JSONB,
  -- Snapshot completo dos dados do período
  observacoes     TEXT,
  status          TEXT DEFAULT 'rascunho',
  -- status: rascunho | finalizado | apresentado
  created_at      TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.relatorios ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Acesso relatórios por UAN" ON public.relatorios
  FOR ALL USING (
    uan_id IN (SELECT id FROM public.uans WHERE consultor_id = auth.uid())
  );

-- ── 13. NOTIFICAÇÕES ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.notificacoes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  uan_id        UUID REFERENCES public.uans(id),
  tipo          TEXT NOT NULL,
  -- tipo: temperatura | nc | prazo_pop | prazo_revisao | conformidade | backup
  severidade    TEXT DEFAULT 'info',
  -- severidade: critica | alerta | info
  titulo        TEXT NOT NULL,
  descricao     TEXT,
  lida          BOOLEAN DEFAULT false,
  link_pagina   TEXT,
  created_at    TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE public.notificacoes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Usuário vê suas notificações" ON public.notificacoes
  FOR ALL USING (user_id = auth.uid());

-- ── 14. ÍNDICES DE PERFORMANCE ────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_checklists_uan_data     ON public.checklists(uan_id, data DESC);
CREATE INDEX IF NOT EXISTS idx_ncs_uan_data            ON public.nao_conformidades(uan_id, data DESC);
CREATE INDEX IF NOT EXISTS idx_ftps_uan                ON public.fichas_tecnicas(uan_id);
CREATE INDEX IF NOT EXISTS idx_ingredientes_ftp        ON public.ftp_ingredientes(ftp_id);
CREATE INDEX IF NOT EXISTS idx_tarefas_uan_status      ON public.tarefas(uan_id, status);
CREATE INDEX IF NOT EXISTS idx_temperaturas_uan_data   ON public.temperaturas(uan_id, data DESC);
CREATE INDEX IF NOT EXISTS idx_notif_user_lida         ON public.notificacoes(user_id, lida);
CREATE INDEX IF NOT EXISTS idx_equipe_uan              ON public.equipe(uan_id);

-- ── 15. DADOS INICIAIS — EQUIPAMENTOS PADRÃO DE TEMPERATURA ───
-- (inseridos quando uma nova UAN é configurada via app)

-- ══════════════════════════════════════════════════════════════
-- FIM DO SETUP
-- Tabelas criadas: 13
-- Execute e depois vá para o app para testar o login
-- ══════════════════════════════════════════════════════════════
