import { useEffect, useRef, useState } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import type { CSSProperties } from 'react';
import { 
  Alert,
  Button, 
  Checkbox, 
  Form, 
  Grid, 
  Input, 
  theme, 
  Typography, 
  Card,
  Space
} from 'antd';
import type { InputRef } from 'antd';
import { 
  LockOutlined, 
  UserOutlined
} from '@ant-design/icons';
import { login, isAuthenticated } from '../utils/auth';
import type { ApiError } from '../utils/apiError';
import { ROUTES } from '../utils/constants';

const { useToken } = theme;
const { useBreakpoint } = Grid;
const { Title } = Typography;

type LoginFormValues = {
  username: string;
  password: string;
  remember?: boolean;
};

const getPostLoginTarget = (pathname: string | undefined): string => {
  if (!pathname || pathname === ROUTES.HOME) {
    return ROUTES.ROUTES;
  }

  return pathname;
};

const describeLoginError = (error: unknown): string => {
  const apiError = (typeof error === 'object' && error !== null ? error : {}) as Partial<ApiError>;

  if (typeof apiError.status !== 'number') {
    return 'Cannot reach the server. Check your connection and try again.';
  }

  if (apiError.status === 400) {
    return 'Invalid request. Please try again.';
  }

  if (apiError.status === 401 || apiError.status === 403) {
    return 'Invalid username or password';
  }

  if (apiError.status === 429) {
    return 'Too many sign-in attempts. Please wait and try again.';
  }

  if (apiError.status >= 500) {
    return 'Server error. Please try again.';
  }

  if (typeof apiError.message === 'string' && apiError.message.length > 0) {
    return apiError.message;
  }

  return 'Sign in failed. Please try again.';
};

const Login = () => {
  const { token } = useToken();
  const screens = useBreakpoint();
  const navigate = useNavigate();
  const location = useLocation();
  const [form] = Form.useForm<LoginFormValues>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const passwordRef = useRef<InputRef>(null);

  // Redirect if already authenticated
  useEffect(() => {
    if (isAuthenticated()) {
      const from = getPostLoginTarget(location.state?.from?.pathname);
      navigate(from, { replace: true });
    }
  }, [navigate, location]);

  const onFinish = async (values: LoginFormValues) => {
    setError(null);

    try {
      setLoading(true);
      await login(values.username, values.password);

      // Redirect to the page the user was trying to access, or to routes
      const from = getPostLoginTarget(location.state?.from?.pathname);
      navigate(from, { replace: true });
    } catch (error) {
      console.error('Login error:', error);
      setError(describeLoginError(error));
      form.setFieldValue('password', '');
      passwordRef.current?.focus();
    } finally {
      setLoading(false);
    }
  };

  const styles: Record<string, CSSProperties> = {
    container: {
      display: 'flex',
      justifyContent: 'center',
      alignItems: 'center',
      minHeight: '100vh',
      background: token.colorBgLayout,
      padding: screens.md ? `${token.paddingXL}px` : `${token.padding}px`,
    },
    card: {
      width: screens.sm ? '400px' : '100%',
      maxWidth: '400px',
      borderRadius: token.borderRadiusLG,
      boxShadow: token.boxShadow,
    },
    header: {
      marginBottom: token.marginLG,
      textAlign: 'center',
    },
    logo: {
      display: 'flex',
      justifyContent: 'center',
      marginBottom: token.marginSM,
    },
    logoImage: {
      width: '100px',
      height: '100px',
    },
    form: {
      width: '100%',
    },
    forgotPassword: {
      float: 'right',
    },
  };

  return (
    <div style={styles.container}>
      <Card style={styles.card}>
        <div style={styles.header}>
          <div style={styles.logo}>
            <img src="/favicon.svg" alt="HydraSRT icon" style={styles.logoImage} />
          </div>
          <Title level={2}>Welcome to HydraSRT</Title>
        </div>
        
        <Form
          form={form}
          name="login_form"
          initialValues={{ remember: true }}
          onFinish={onFinish}
          layout="vertical"
          style={styles.form}
          size="large"
        >
          <Form.Item
            name="username"
            rules={[{ required: true, message: 'Please input your username!' }]}
          >
            <Input 
              prefix={<UserOutlined />} 
              placeholder="Username" 
              autoComplete="username"
            />
          </Form.Item>
          
          <Form.Item
            name="password"
            rules={[{ required: true, message: 'Please input your password!' }]}
          >
            <Input.Password
              prefix={<LockOutlined />}
              placeholder="Password"
              autoComplete="current-password"
              ref={passwordRef}
            />
          </Form.Item>

          {error ? (
            <Form.Item>
              <Alert type="error" showIcon role="alert" data-testid="login-error" message={error} />
            </Form.Item>
          ) : null}
          
          <Form.Item>
            <Space style={{ width: '100%', justifyContent: 'space-between' }}>
              <Form.Item name="remember" valuePropName="checked" noStyle>
                <Checkbox>Remember me</Checkbox>
              </Form.Item>
              {/* <Link style={styles.forgotPassword}>Forgot password?</Link> */}
            </Space>
          </Form.Item>
          
          <Form.Item>
            <Button 
              type="primary" 
              htmlType="submit" 
              block 
              loading={loading}
            >
              Sign In
            </Button>
          </Form.Item>
          
        </Form>
      </Card>
    </div>
  );
};

export default Login; 
