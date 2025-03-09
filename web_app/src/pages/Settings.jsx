import React, { useEffect } from 'react';
import { Typography, Form, Input, Switch, Button, Card, Space, Divider } from 'antd';
import { HomeOutlined } from '@ant-design/icons';

const { Title } = Typography;

const Settings = () => {
  const [form] = Form.useForm();

  // Set breadcrumb items for the Settings page
  useEffect(() => {
    if (window.setBreadcrumbItems) {
      window.breadcrumbSet = true;
      window.setBreadcrumbItems([
        {
          href: '/',
          title: <HomeOutlined />,
        },
        {
          href: '/settings',
          title: 'Settings',
        }
      ]);
    }
  }, []);

  return (
    <div>
      <Title level={2}>Settings</Title>
      
      <Card>
        <Form
          form={form}
          layout="vertical"
          initialValues={{
            notifications: true,
            darkMode: false,
          }}
        >
          <Form.Item label="Email" name="email">
            <Input placeholder="Enter your email" />
          </Form.Item>

          <Form.Item label="API Key" name="apiKey">
            <Input.Password />
          </Form.Item>

          <Divider />

          <Form.Item label="Notifications" name="notifications" valuePropName="checked">
            <Switch />
          </Form.Item>

          <Form.Item label="Dark Mode" name="darkMode" valuePropName="checked">
            <Switch />
          </Form.Item>

          <Form.Item>
            <Space>
              <Button type="primary">Save Changes</Button>
              <Button>Reset</Button>
            </Space>
          </Form.Item>
        </Form>
      </Card>
    </div>
  );
};

export default Settings; 