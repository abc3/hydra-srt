import { useState, useEffect } from 'react';
import PropTypes from 'prop-types';
import {
  MenuFoldOutlined,
  MenuUnfoldOutlined,
  CompassOutlined,
  CloudServerOutlined,
  SettingOutlined,
  LogoutOutlined,
  HomeOutlined,
  ApiOutlined,
  CodeOutlined,
  MessageOutlined,
} from '@ant-design/icons';
import { Button, Layout, Menu, Grid, Dropdown, message, Breadcrumb, Tooltip } from 'antd';
import { useLocation, useNavigate } from 'react-router-dom';
import { logout, getUser } from '../utils/auth';
import { ROUTES } from '../utils/constants';
import React from 'react';

const { Sider, Content } = Layout;
const { useBreakpoint } = Grid;
const feedbackUrl = 'https://github.com/abc3/hydra-srt/issues/new';

const getDefaultBreadcrumbItems = (path) => {
  if (path.startsWith(ROUTES.ROUTES)) {
    if (path === ROUTES.ROUTES) {
      return [
        {
          href: ROUTES.ROUTES,
          title: <HomeOutlined />,
        },
        {
          title: 'Routes',
        }
      ];
    }

    return [
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      }
    ];
  }

  if (path.startsWith(ROUTES.SETTINGS)) {
    return [
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      },
      {
        title: 'Settings',
      }
    ];
  }

  if (path.startsWith(ROUTES.INTERFACES)) {
    return [
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      },
      {
        title: 'Interfaces',
      }
    ];
  }

  if (path.startsWith(ROUTES.SYSTEM_PIPELINES)) {
    return [
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      },
      {
        title: 'System Pipelines',
      }
    ];
  }

  if (path.startsWith(ROUTES.SYSTEM_NODES)) {
    return [
      {
        href: ROUTES.ROUTES,
        title: <HomeOutlined />,
      },
      {
        title: 'System Nodes',
      }
    ];
  }

  return [
    {
      href: ROUTES.ROUTES,
      title: <HomeOutlined />,
    }
  ];
};

const MainLayout = ({ children }) => {
  const [collapsed, setCollapsed] = useState(false);
  const [user, setUser] = useState(null);
  const [breadcrumbItems, setBreadcrumbItems] = useState([]);
  const screens = useBreakpoint();
  const navigate = useNavigate();
  const location = useLocation();
  // Expose setBreadcrumbItems to window object for child components
  useEffect(() => {
    window.setBreadcrumbItems = setBreadcrumbItems;

    return () => {
      delete window.setBreadcrumbItems;
    };
  }, []);

  useEffect(() => {
    setCollapsed(!screens.md);
  }, [screens.md]);

  useEffect(() => {
    // Get user from localStorage
    const userData = getUser();
    setUser(userData);
  }, []);

  useEffect(() => {
    setBreadcrumbItems(getDefaultBreadcrumbItems(location.pathname));
  }, [location.pathname]);

  const handleLogout = () => {
    // Use the logout function from auth.js
    logout();
    message.success('Logged out successfully');
  };

  const dropdownItems = {
    items: [
      {
        key: '1',
        icon: <LogoutOutlined style={{ color: '#ff4d4f' }} />,
        label: <span style={{ color: '#ff4d4f' }}>Log out</span>,
        onClick: handleLogout,
      },
    ],
  };

  const menuItems = [
    {
      key: ROUTES.ROUTES,
      icon: <CompassOutlined />,
      label: 'Routes',
    },
    {
      key: ROUTES.INTERFACES,
      icon: <ApiOutlined />,
      label: 'Interfaces',
    },
    {
      key: ROUTES.SYSTEM_PIPELINES,
      icon: <CodeOutlined />,
      label: 'Pipelines',
    },
    {
      key: ROUTES.SYSTEM_NODES,
      icon: <CloudServerOutlined />,
      label: 'Nodes',
    },
    {
      key: ROUTES.SETTINGS,
      icon: <SettingOutlined />,
      label: 'Settings',
    },
  ];

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Sider
        trigger={null}
        collapsible
        collapsed={collapsed}
        breakpoint="md"
        collapsedWidth={screens.xs ? 0 : 80}
        onBreakpoint={(broken) => {
          setCollapsed(broken);
        }}
        style={{
          boxShadow: 'none',
          zIndex: 10,
          borderRight: '1px solid #1a1a1a',
          position: 'relative',
          display: 'flex',
          flexDirection: 'column',
          height: '100vh',
          paddingBottom: 0,
          overflow: 'hidden',
        }}
      >
        <div
          style={{
            height: 32,
            margin: '16px 16px 24px',
            display: 'flex',
            alignItems: 'center',
            color: 'white',
            fontWeight: 'bold',
            fontSize: '16px',
            justifyContent: 'space-between',
          }}
        >
          <div 
            style={{ 
              display: 'flex', 
              alignItems: 'center',
              cursor: 'pointer' 
            }}
            onClick={() => navigate(ROUTES.ROUTES)}
          >
            <img src="/favicon.svg" alt="HydraSRT Logo" style={{ width: '40px', height: '40px', marginRight: '8px' }} />
            {!collapsed && 'HydraSRT'}
          </div>
          {!screens.xs && (
            <Button
              type="text"
              icon={collapsed ? <MenuUnfoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} /> : <MenuFoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} />}
              onClick={() => setCollapsed(!collapsed)}
              style={{
                fontSize: '14px',
                padding: 0,
                width: 24,
                height: 24,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
              }}
            />
          )}
        </div>
        <div style={{ 
          overflowY: 'auto', 
          flex: '1 1 auto',
          paddingBottom: collapsed ? 72 : 84,
        }}>
          <Menu
            theme="dark"
            mode="inline"
            selectedKeys={[
              location.pathname.startsWith(`${ROUTES.ROUTES}/`)
                ? ROUTES.ROUTES
                : location.pathname.startsWith(`${ROUTES.INTERFACES}/`)
                  ? ROUTES.INTERFACES
                  : location.pathname.startsWith(`${ROUTES.SETTINGS}/`)
                    ? ROUTES.SETTINGS
                    : location.pathname.startsWith(ROUTES.SYSTEM_PIPELINES)
                      ? ROUTES.SYSTEM_PIPELINES
                      : location.pathname.startsWith(ROUTES.SYSTEM_NODES)
                        ? ROUTES.SYSTEM_NODES
                        : location.pathname
            ]}
            items={menuItems.map(item => ({
              ...item,
              icon: React.cloneElement(item.icon, {
                style: { fontSize: '16px' }
              })
            }))}
            onClick={({ key }) => navigate(key)}
            style={{ 
              padding: '0 8px',
              background: 'transparent',
              border: 'none',
            }}
          />
        </div>
        
        <div
          style={{
            borderTop: '1px solid #1a1a1a',
            width: '100%',
            position: 'absolute',
            bottom: 0,
            left: 0,
            right: 0,
            background: '#000000',
          }}
        >
          <Tooltip title="Request a feature or report a bug" placement={collapsed ? 'right' : 'top'}>
            <a
              href={feedbackUrl}
              target="_blank"
              rel="noreferrer"
              aria-label="Request a feature or report a bug"
              style={{
                minHeight: collapsed ? 56 : 68,
                padding: collapsed ? '12px 0' : '12px 16px',
                borderBottom: '1px solid #1a1a1a',
                color: 'rgba(255, 255, 255, 0.78)',
                display: 'flex',
                alignItems: 'center',
                justifyContent: collapsed ? 'center' : 'flex-start',
                gap: 12,
                textDecoration: 'none',
                transition: 'color 0.2s, background 0.2s',
              }}
              onMouseEnter={(e) => {
                e.currentTarget.style.color = '#ffffff';
                e.currentTarget.style.background = 'rgba(255, 255, 255, 0.04)';
              }}
              onMouseLeave={(e) => {
                e.currentTarget.style.color = 'rgba(255, 255, 255, 0.78)';
                e.currentTarget.style.background = 'transparent';
              }}
            >
              <MessageOutlined style={{ fontSize: 16 }} />
              {!collapsed && (
                <span
                  style={{
                    display: 'flex',
                    flexDirection: 'column',
                    lineHeight: 1.2,
                  }}
                >
                  <span style={{ fontSize: 14, fontWeight: 500 }}>Feedback</span>
                  <span style={{ color: 'rgba(255, 255, 255, 0.45)', fontSize: 12 }}>
                    Request a feature or report a bug
                  </span>
                </span>
              )}
            </a>
          </Tooltip>
        </div>
      </Sider>
      <Layout style={{ 
        position: 'relative', 
        zIndex: 1,
        marginLeft: collapsed ? 0 : 0,
      }}>
        <div
          style={{
            padding: '0 16px',
            background: '#000000',
            top: 0,
            zIndex: 9,
            width: '100%',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            boxShadow: 'none',
            borderBottom: '1px solid #1a1a1a',
            height: 56,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', height: '100%' }}>
            {screens.xs && (
              <Button
                type="text"
                icon={collapsed ? <MenuUnfoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} /> : <MenuFoldOutlined style={{ color: 'rgba(255, 255, 255, 0.65)' }} />}
                onClick={() => setCollapsed(!collapsed)}
                style={{
                  fontSize: '16px',
                  marginRight: '16px',
                }}
              />
            )}
            <Breadcrumb 
              items={breadcrumbItems}
              onClick={(e) => {
                const target = e.target.closest('a');
                if (target) {
                  e.preventDefault();
                  const href = target.getAttribute('href');
                  if (href) {
                    navigate(href);
                  }
                }
              }}
              style={{
                color: 'rgba(255, 255, 255, 0.65)',
              }}
            />
          </div>
          <Dropdown
            menu={dropdownItems}
            trigger={['click']}
            placement="bottomRight"
          >
            <Button
              type="text"
              style={{
                height: 44,
                padding: '6px 12px',
                borderRadius: 6,
                display: 'flex',
                alignItems: 'center',
                color: 'rgba(255, 255, 255, 0.85)',
                fontSize: 14,
                fontWeight: 500,
              }}
            >
              {user || 'admin'}
            </Button>
          </Dropdown>
        </div>
        <Content
          style={{
            margin: 0,
            padding: 21,
            minHeight: 280,
            borderRadius: 4,
            overflow: 'auto',
            boxShadow: 'none',
            position: 'relative',
            zIndex: 1,
          }}
        >
          {children}
        </Content>
      </Layout>
    </Layout>
  );
};

MainLayout.propTypes = {
  children: PropTypes.node.isRequired,
};

export default MainLayout;
