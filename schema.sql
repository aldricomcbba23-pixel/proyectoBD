-- =============================================================================
-- BASE DE DATOS: bd_bar
-- MOTOR: PostgreSQL (Ejecutar en pgAdmin 4 -> Query Tool de la base bd_bar)
-- ARQUITECTURA: Modelo Entidad-Relación Normalizado (6 Tablas Relacionadas)
-- PROPÓSITO: Sistema de Registro de Compras y Ventas, Control y Balance de Caja
-- =============================================================================

-- =============================================================================
-- 1. TABLAS MAESTRAS / CATÁLOGOS (ENTIDADES PADRE)
-- =============================================================================

-- TABLA 1 (Superior Izquierda): usuarios (Personal / Cajeros)
CREATE TABLE IF NOT EXISTS public.usuarios (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(100) NOT NULL UNIQUE,
    rol VARCHAR(50) NOT NULL DEFAULT 'Cajero',
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE public.usuarios IS 'Personal y cajeros autorizados para operar compras y ventas.';

-- TABLA 2 (Inferior Izquierda): clientes (Clientes / Proveedores / Destinos)
CREATE TABLE IF NOT EXISTS public.clientes (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(150) NOT NULL UNIQUE,
    telefono VARCHAR(50) NULL,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE public.clientes IS 'Directorio de clientes, proveedores o destinos de operaciones.';

-- TABLA 3 (Derecha): categorias_productos (Catálogo de productos, insumos y compras)
CREATE TABLE IF NOT EXISTS public.categorias_productos (
    id BIGSERIAL PRIMARY KEY,
    nombre VARCHAR(150) NOT NULL UNIQUE,
    tipo VARCHAR(50) NOT NULL DEFAULT 'GENERAL' CHECK (tipo IN ('PRODUCTO', 'INSUMO', 'SERVICIO', 'GENERAL')),
    descripcion TEXT NULL
);

COMMENT ON TABLE public.categorias_productos IS 'Catálogo común para clasificación de productos de venta e insumos de compra.';


-- =============================================================================
-- 2. TABLA CENTRAL: registros_operativos (MOVIMIENTOS DE COMPRAS Y VENTAS)
-- Cada compra o venta cuenta con su identificador único (id)
-- =============================================================================

-- TABLA 4 (Centro): registros_operativos
CREATE TABLE IF NOT EXISTS public.registros_operativos (
    id BIGSERIAL PRIMARY KEY,
    fecha_hora TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    usuario_id BIGINT NOT NULL,
    cliente_id BIGINT NULL,
    usuario VARCHAR(100) NOT NULL DEFAULT 'Cajero General',
    tipo_evento VARCHAR(20) NOT NULL,
    monto NUMERIC(12, 2) NOT NULL DEFAULT 0.00,
    detalle TEXT NOT NULL DEFAULT 'Operación de caja',
    cliente_destino VARCHAR(150) NULL,

    -- Restricciones de integridad (Registro de Compras y Ventas)
    CONSTRAINT chk_tipo_evento CHECK (tipo_evento IN ('VENTA', 'COMPRA', 'INGRESO', 'EGRESO', 'OTRO')),
    CONSTRAINT chk_monto_positivo CHECK (monto >= 0),

    -- Relaciones / Llaves Foráneas (Diagrama ER Normalizado)
    CONSTRAINT fk_reg_usuario FOREIGN KEY (usuario_id) 
        REFERENCES public.usuarios(id) ON UPDATE CASCADE,
    CONSTRAINT fk_reg_cliente FOREIGN KEY (cliente_id) 
        REFERENCES public.clientes(id) ON UPDATE CASCADE ON DELETE SET NULL
);

COMMENT ON TABLE public.registros_operativos IS 'Tabla central que registra cada transacción (VENTA o COMPRA) con su ID único y monto.';


-- =============================================================================
-- 3. TABLAS DE DETALLE RELACIONALES (VENTAS Y COMPRAS)
-- =============================================================================

-- TABLA 5 (Superior Centro): ingresos_detalles (Líneas de venta / ingresos)
CREATE TABLE IF NOT EXISTS public.ingresos_detalles (
    id BIGSERIAL PRIMARY KEY,
    registro_id BIGINT NOT NULL,
    categoria_id BIGINT NOT NULL,
    cantidad NUMERIC(10, 2) NOT NULL DEFAULT 1.00,
    subtotal NUMERIC(12, 2) NOT NULL DEFAULT 0.00,

    -- Llaves Foráneas
    CONSTRAINT fk_ingreso_registro FOREIGN KEY (registro_id) 
        REFERENCES public.registros_operativos(id) ON DELETE CASCADE,
    CONSTRAINT fk_ingreso_categoria FOREIGN KEY (categoria_id) 
        REFERENCES public.categorias_productos(id) ON UPDATE CASCADE
);

COMMENT ON TABLE public.ingresos_detalles IS 'Desglose detallado de ventas vinculado al movimiento central y categorías.';

-- TABLA 6 (Inferior Centro): egresos_detalles (Líneas de compras / egresos)
CREATE TABLE IF NOT EXISTS public.egresos_detalles (
    id BIGSERIAL PRIMARY KEY,
    registro_id BIGINT NOT NULL,
    categoria_id BIGINT NOT NULL,
    comprobante VARCHAR(100) NULL,
    subtotal NUMERIC(12, 2) NOT NULL DEFAULT 0.00,

    -- Llaves Foráneas
    CONSTRAINT fk_egreso_registro FOREIGN KEY (registro_id) 
        REFERENCES public.registros_operativos(id) ON DELETE CASCADE,
    CONSTRAINT fk_egreso_categoria FOREIGN KEY (categoria_id) 
        REFERENCES public.categorias_productos(id) ON UPDATE CASCADE
);

COMMENT ON TABLE public.egresos_detalles IS 'Desglose detallado de compras vinculado al movimiento central y categorías.';


-- =============================================================================
-- 4. ÍNDICES DE RENDIMIENTO PARA POSTGREST
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_reg_fecha_hora ON public.registros_operativos (fecha_hora DESC);
CREATE INDEX IF NOT EXISTS idx_reg_tipo_evento ON public.registros_operativos (tipo_evento);
CREATE INDEX IF NOT EXISTS idx_reg_usuario ON public.registros_operativos (usuario);
CREATE INDEX IF NOT EXISTS idx_reg_usuario_id ON public.registros_operativos (usuario_id);
CREATE INDEX IF NOT EXISTS idx_reg_cliente_id ON public.registros_operativos (cliente_id);

CREATE INDEX IF NOT EXISTS idx_ingreso_reg_id ON public.ingresos_detalles (registro_id);
CREATE INDEX IF NOT EXISTS idx_ingreso_cat_id ON public.ingresos_detalles (categoria_id);

CREATE INDEX IF NOT EXISTS idx_egreso_reg_id ON public.egresos_detalles (registro_id);
CREATE INDEX IF NOT EXISTS idx_egreso_cat_id ON public.egresos_detalles (categoria_id);


-- =============================================================================
-- 5. TRIGGERS DE SINCRONIZACIÓN AUTOMÁTICA
-- =============================================================================

-- Trigger 1 (BEFORE INSERT): Sincroniza usuario_id y cliente_id con sus respectivas tablas
CREATE OR REPLACE FUNCTION public.fn_sincronizar_claves_foraneas()
RETURNS TRIGGER AS $$
DECLARE
    v_usuario_id BIGINT;
    v_cliente_id BIGINT;
BEGIN
    -- Asignar usuario por defecto si no se especifica
    IF NEW.usuario IS NULL OR TRIM(NEW.usuario) = '' THEN
        NEW.usuario := 'Cajero General';
    END IF;

    -- Asignar detalle por defecto si no se especifica
    IF NEW.detalle IS NULL OR TRIM(NEW.detalle) = '' THEN
        IF NEW.tipo_evento = 'VENTA' THEN
            NEW.detalle := 'Venta realizada';
        ELSIF NEW.tipo_evento = 'COMPRA' THEN
            NEW.detalle := 'Compra de insumos/servicios';
        ELSE
            NEW.detalle := NEW.tipo_evento;
        END IF;
    END IF;

    -- Sincronizar o crear usuario en tabla usuarios
    SELECT id INTO v_usuario_id FROM public.usuarios WHERE nombre = NEW.usuario;
    IF v_usuario_id IS NULL THEN
        INSERT INTO public.usuarios (nombre) VALUES (NEW.usuario) RETURNING id INTO v_usuario_id;
    END IF;
    NEW.usuario_id := v_usuario_id;

    -- Sincronizar o crear cliente si se especifica cliente_destino
    IF NEW.cliente_destino IS NOT NULL AND TRIM(NEW.cliente_destino) <> '' THEN
        SELECT id INTO v_cliente_id FROM public.clientes WHERE nombre = NEW.cliente_destino;
        IF v_cliente_id IS NULL THEN
            INSERT INTO public.clientes (nombre) VALUES (NEW.cliente_destino) RETURNING id INTO v_cliente_id;
        END IF;
        NEW.cliente_id := v_cliente_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_pre_registro_operativo ON public.registros_operativos;
CREATE TRIGGER trg_pre_registro_operativo
BEFORE INSERT OR UPDATE ON public.registros_operativos
FOR EACH ROW
EXECUTE FUNCTION public.fn_sincronizar_claves_foraneas();

-- Trigger 2 (AFTER INSERT): Asienta automáticamente el detalle en compras/ventas
CREATE OR REPLACE FUNCTION public.fn_poblar_detalles_relacionales()
RETURNS TRIGGER AS $$
DECLARE
    v_categoria_id BIGINT;
BEGIN
    -- Obtener o inicializar categoría en el catálogo
    SELECT id INTO v_categoria_id FROM public.categorias_productos WHERE nombre = 'General';
    IF v_categoria_id IS NULL THEN
        INSERT INTO public.categorias_productos (nombre, tipo) VALUES ('General', 'GENERAL') RETURNING id INTO v_categoria_id;
    END IF;

    -- Si es VENTA o INGRESO, asentar en tabla ingresos_detalles
    IF NEW.tipo_evento IN ('VENTA', 'INGRESO') THEN
        INSERT INTO public.ingresos_detalles (registro_id, categoria_id, cantidad, subtotal)
        VALUES (NEW.id, v_categoria_id, 1, NEW.monto);

    -- Si es COMPRA o EGRESO, asentar en tabla egresos_detalles
    ELSIF NEW.tipo_evento IN ('COMPRA', 'EGRESO') THEN
        INSERT INTO public.egresos_detalles (registro_id, categoria_id, comprobante, subtotal)
        VALUES (NEW.id, v_categoria_id, SUBSTRING(NEW.detalle FROM 1 FOR 100), NEW.monto);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_post_registro_operativo ON public.registros_operativos;
CREATE TRIGGER trg_post_registro_operativo
AFTER INSERT ON public.registros_operativos
FOR EACH ROW
EXECUTE FUNCTION public.fn_poblar_detalles_relacionales();


-- =============================================================================
-- 6. PERMISOS Y ROLES PARA POSTGREST (ROL web_anon)
-- =============================================================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO web_anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO web_anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_anon;
