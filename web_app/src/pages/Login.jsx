import React, { useState, useEffect } from 'react';
import { useNavigate, useLocation } from 'react-router-dom';
import { 
  Button, 
  Checkbox, 
  Form, 
  Grid, 
  Input, 
  theme, 
  Typography, 
  Card,
  Space,
  message
} from 'antd';
import { 
  LockOutlined, 
  UserOutlined,
  LoginOutlined
} from '@ant-design/icons';
import { login, isAuthenticated } from '../utils/auth';
import { ROUTES } from '../utils/constants';

const { useToken } = theme;
const { useBreakpoint } = Grid;
const { Title, Text, Link } = Typography;

const Login = () => {
  const { token } = useToken();
  const screens = useBreakpoint();
  const navigate = useNavigate();
  const location = useLocation();
  const [loading, setLoading] = useState(false);

  // Redirect if already authenticated
  useEffect(() => {
    if (isAuthenticated()) {
      const from = location.state?.from?.pathname || ROUTES.DASHBOARD;
      navigate(from, { replace: true });
    }
  }, [navigate, location]);

  const onFinish = async (values) => {
    try {
      setLoading(true);
      
      // Call the login function from auth.js
      await login(values.username, values.password);
      
      message.success('Login successful!');
      
      // Redirect to the page the user was trying to access, or to the dashboard
      const from = location.state?.from?.pathname || ROUTES.DASHBOARD;
      navigate(from, { replace: true });
    } catch (error) {
      console.error('Login error:', error);
      message.error('Invalid username or password');
    } finally {
      setLoading(false);
    }
  };

  const styles = {
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
      fontSize: '32px',
      color: token.colorPrimary,
      marginBottom: token.marginSM,
    },
    form: {
      width: '100%',
    },
    footer: {
      marginTop: token.marginLG,
      textAlign: 'center',
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
            <LoginOutlined />
          </div>
          <Title level={2}>Welcome to Hydra</Title>
          <Text type="secondary">
            Please sign in to access your account
          </Text>
        </div>
        
        <Form
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
            />
          </Form.Item>
          
          <Form.Item>
            <Space style={{ width: '100%', justifyContent: 'space-between' }}>
              <Form.Item name="remember" valuePropName="checked" noStyle>
                <Checkbox>Remember me</Checkbox>
              </Form.Item>
              <Link style={styles.forgotPassword}>
                Forgot password?
              </Link>
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
          
          <div style={styles.footer}>
            <Text type="secondary">
              Don't have an account? Contact administrator
            </Text>
          </div>
        </Form>
      </Card>
    </div>
  );
};

export default Login; 